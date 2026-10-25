namespace :demo_user do
  desc "Provision a demo user explicitly from environment variables"
  task provision: :environment do
    DemoUsers::Provision.new(email: ENV["DEMO_USER_EMAIL"], password: ENV["DEMO_USER_PASSWORD"]).call
    puts "Demo user provisioned"
  rescue DemoUsers::Provision::Error => error
    abort error.message
  end
end
