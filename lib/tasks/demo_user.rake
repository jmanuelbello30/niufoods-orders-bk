namespace :demo_user do
  desc "Provision a demo user explicitly from environment variables"
  task provision: :environment do
    email = ENV["DEMO_USER_EMAIL"]
    password = ENV["DEMO_USER_PASSWORD"]
    abort "Set DEMO_USER_EMAIL and DEMO_USER_PASSWORD" if email.blank? || password.blank?
    abort "User already exists; credentials were not changed" if User.exists?(email: email)

    user = User.new(email: email, password: password)
    if user.save
      puts "Demo user provisioned"
    else
      abort "Invalid demo user: #{user.errors.full_messages.join(', ')}"
    end
  end
end
