class DeathRecordsController < ApplicationController
  before_action :new_death_record, only: [:new]
  before_action :set_death_record, only: [:show, :edit, :update_step, :update_active_step, :register, :request_edits]
  before_action :set_transferred_death_records, only: [:index]
  before_action :set_owned_death_records, only: [:index]
  before_action :set_comments, only: [:show, :edit]

  # Render dashboard view.
  def index
  end

  # Render DeathRecord summary view.
  def show
  end

  # Create a new DeathRecord and redirect to edit.
  def new
    redirect_to edit_death_record_url @death_record
  end

  # Render DeathRecord edit view.
  def edit
  end

  # Update the DeathRecord.
  def update
    # TODO
  end

  # Update a specific step's contents.
  def update_step
    # If the current User isn't supposed to edit the DeathRecord at the
    # current Step, do nothing.
    step = @death_record.step_status.current_step
    return unless @death_record.step_editable?(current_user, step)
    create_or_update_step_history(step, @death_record, current_user)
    step_content = StepContent.update_or_create_new(death_record: @death_record,
                                                    step: step,
                                                    contents: death_record_params,
                                                    editor: current_user)
    @death_record.increment_step
    render json: @death_record.cached_json
  end

  # Update the active Step of the DeathRecord. Also addresses cases when
  # a Step change calls for the DeathRecord to be ed to another User.
  def update_active_step
    # If the current User isn't supposed to edit the DeathRecord at the
    # current Step, do nothing.
    return unless @death_record.step_editable?(current_user, @death_record.step_status.current_step)

    # Don't allow guests sending to guests!
    return if GuestHelper.guest_user_exists?(params['email']) && params['guestMode']

    # Are we going to send the DeathRecord to a guest?
    if params['guestMode'] == "true"
      # Sending to a guest; need to create guest user, token, and token link.
      user = GuestHelper.generate_user(params['email'],
                                       params['firstName'],
                                       params['lastName'],
                                       params['telephone'],
                                       @death_record.step_flow.send_to_role)
      guest_token = GuestHelper.generate_user_token(user, @death_record)
      token_link = GuestHelper.generate_login_link(guest_token, root_url)

      # Send an email to the guest.
      GuestHelper.send_login_link(user, token_link)
    else
      # Not sending to a guest; proceed normally.
      user = params['email'].present? ? User.find_by(email: params['email']) : current_user
    end

    # Get next step
    if @death_record.step_status.current_step.step_type == 'review' && death_record_params[:reassign]
      # Next step is not supposed to be filled out by this user, as this is
      # a transition.
      step = @death_record.workflow.step_flows.find_by(current_step: @death_record.step_status.current_step).next_step
    else
      # The next step is editable by the current user.
      step = @death_record.editable_step_by_name(user, death_record_params[:step])
    end

    # If the (potential) next User isn't supposed to edit the next Step,
    # do nothing. Be careful about the next user being a guest.
    return unless params['guestMode'] || @death_record.step_editable?(user, step)

    # Update the DeathRecord owner
    @death_record.update_owner(user)

    # Update the DeathRecord StepStatus. Force a linear transition if the
    # death record is being reassigned.
    linear = params[:linear].is_a?(String) ? params[:linear] == 'true' : params[:linear]
    @death_record.update_step(step, linear)

    # If the DeathRecord was reassigned, check if the current user is a guest
    # (and invalidate their access token), else redirect to the dashboard.
    if user != current_user
      # Backfill any missing StepContents for form steps before continuing
      @death_record.steps_editable(current_user).each do |step|
        if !@death_record.step_contents.exists?(step: step) && step.step_type == 'form'
          step_content = StepContent.update_or_create_new(death_record: @death_record,
                                                          step: step,
                                                          contents: {},
                                                          editor: current_user)
        end
      end
      # Step history for transfer
      create_or_update_step_history(step, @death_record, current_user)
      # Invalidate guest user who has finished with this DeathRecord.
      if current_user.is_guest_user
        guest_token = UserToken.find_by(death_record: @death_record, user: current_user)
        guest_token.expire_token!
        sign_out(current_user)
      end
      # Redirect to dashboard
      render js: "window.location.href='#{death_records_path}'"
      return
    end

    # Return current state
    render json: @death_record.cached_json
  end

  # Register the current record.
  def register
    return unless current_user.can_register_record?
    step = @death_record.step_status.current_step
    create_or_update_step_history(step, @death_record, current_user)
    @death_record.registration = Registration.new(registered: DateTime.now)
    @death_record.registration.save
    @death_record.owner = nil
    @death_record.update_cache
    @death_record.save
    render json: @death_record.cached_json
  end

  # Handles requesting edits from users.
  def request_edits
    return unless current_user.can_request_edits?
    create_or_update_step_history(@death_record.step_status.current_step, @death_record, current_user)
    user = User.find_by(email: death_record_params['email'])
    step = @death_record.editable_step_by_name(user, death_record_params[:step])
    @death_record.update_step(step, true)
    @death_record.update_owner(user)
    # Redirect to dashboard
    render js: "window.location.href='#{death_records_path}'"
    return
  end

  # Return a list of users given a role
  def users_by_role
    render :json => User.with_role(params[:role]).map { |user| "#{user.email} (#{NameHelper.pretty_user_name(user)})" }
  end

  private

  # Create a new DeathRecord within the context of the current user and their
  # role.
  def new_death_record
    # Check if the current user is allowed to create death records.
    return unless current_user.can_start_record?

    # Set the workflow to the latest version for the owners role.
    workflow = Workflow.where(initiator_role: current_user.roles.first.name).order("created_at").last

    # Set the active StepFlow as the first StepFlow of the workflow.
    step_flow = workflow.step_flows.first

    # Create new DeathRecord
    @death_record = DeathRecord.new(creator: current_user,
                                       owner: current_user,
                                       workflow: workflow,
                                       step_flow: step_flow)

    # Create and and set a StepStatus for this DeathRecord.
    step_status = StepStatus.create(death_record: @death_record,
                                    current_step: step_flow.current_step,
                                    next_step: step_flow.next_step,
                                    previous_step: step_flow.previous_step)
    @death_record.step_status = step_status
    @death_record.update_cache
    @death_record.save
  end

  # Retrieve the DeathRecord requested by id (and scope by owner). Admins
  # have access to any DeathRecord, regardless of ownership.
  def set_death_record
    if current_user.admin?
      @death_record = DeathRecord.find(params[:id])
    else
      @death_record = current_user.owned_death_records.find_by(id: params[:id])
      # Allow viewing of death records that were touched but aren't
      # currently owned.
      if @death_record.nil?
        set_transferred_death_records
        @death_record = @transferred_death_records.select{ |record| record.id.to_s == params[:id].to_s }.first
      end
    end
  end

  # Retrieve all DeathRecords currently owned by this user.
  def set_owned_death_records
    if current_user.admin?
      @owned_death_records = DeathRecord.all
    else
      @owned_death_records = current_user.owned_death_records
    end
  end

  # Retrieve all DeathRecords created by this user (that aren't currently
  # owned by this user).
  def set_transferred_death_records
    transferred = []
    current_user.step_histories.includes(:death_record).each do |history|
      transferred.push(history.death_record) unless current_user.registrar? && history.death_record.registration.nil?
    end
    @transferred_death_records = transferred - current_user.owned_death_records
  end

  # Retrieve all Comments for this DeathRecord
  def set_comments
    @comments = @death_record.comments.collect(&:content)
  end

  # Create a whitelist of params; these are generated dynamically from the
  # curently active step. This means the only parameters accepted at any
  # point is scoped by the active Step.
  def death_record_params
    whitelist = @death_record.step_status.current_step.whitelist
    whitelist = [] if whitelist.nil?
    allows = [:firstName, :lastName, :telephone, :email, :step, :guestEmail,
              :confirmEmail, :linear, :guestMode, :id, :reassign]
    params.permit(whitelist + allows)
  end

  # Helper method that handles creating or updating StepHistories.
  def create_or_update_step_history(step, death_record, user)
    # TODO: Might need to check if a step history already exists and modify it.
    step_history = StepHistory.create(step: step,
                                      death_record: @death_record,
                                      user: current_user,
                                      time_taken: Time.now - @death_record.updated_at.to_time)
    step_history.save
  end
end
