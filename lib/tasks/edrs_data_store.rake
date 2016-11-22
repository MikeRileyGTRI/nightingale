namespace :edrs_data_store do
  namespace :users do

    desc %{Creates a new user.

    You must identify an email address and password:

    $ rake edrs_data_store:users:create EMAIL=### PASS=###}
    task create: :environment do
      if User.create!(:email => ENV['EMAIL'], :password => ENV['PASS'])
        puts "The user was created successfully."
      else
        puts "The user was not created!"
      end
    end

    desc %{Deletes a user.

    You must identify an email address:

    $ rake edrs_data_store:users:delete EMAIL=###}
    task delete: :environment do
      user = User.find_by(:email => ENV['EMAIL'])
      if !user.nil? && user.destroy
        puts "The user was deleted successfully."
      elsif !user.nil?
        puts "The user was not deleted!"
      else
        puts "User not found!"
      end
    end

    desc %{Prints a list of users.}
    task list: :environment do
      users = User.all
      users.each do |user|
        user.roles.each do |role|
          puts 'Email: ' + user.email
        end
      end
    end

  end
end