ENV["RAILS_ENV"] ||= "test"
ENV.delete("DEMO_USER_EMAIL")
ENV.delete("DEMO_USER_PASSWORD")
require_relative "../config/environment"
unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.to_s.match?(/\Aniufoods_orders_test(?:_\d+)?\z/)
  abort "Tests require an isolated niufoods_orders_test database"
end
require "rails/test_help"
require_relative "support/api_authentication_helper"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
