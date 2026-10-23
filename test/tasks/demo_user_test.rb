require "test_helper"
require "rake"

class DemoUserTest < ActiveSupport::TestCase
  setup do
    @original_email = ENV["DEMO_USER_EMAIL"]
    @original_password = ENV["DEMO_USER_PASSWORD"]
    ENV["DEMO_USER_EMAIL"] = "demo@example.test"
    ENV["DEMO_USER_PASSWORD"] = "demo-password-123"
    @original_rake_application = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load Rails.root.join("lib/tasks/demo_user.rake")
    @task = Rake::Task["demo_user:provision"]
  end

  teardown do
    ENV["DEMO_USER_EMAIL"] = @original_email
    ENV["DEMO_USER_PASSWORD"] = @original_password
    Rake.application = @original_rake_application
  end

  test "provisions a user only from explicit environment credentials without printing the password" do
    output, errors = capture_io do
      assert_difference "User.count", 1 do
        @task.invoke
      end
    end

    user = User.find_by!(email: ENV.fetch("DEMO_USER_EMAIL"))
    assert user.authenticate(ENV.fetch("DEMO_USER_PASSWORD"))
    assert_includes output, "Demo user provisioned"
    assert_empty errors
    assert_not_includes output + errors, ENV.fetch("DEMO_USER_PASSWORD")
  end

  test "requires both environment credentials without using defaults" do
    [ "DEMO_USER_EMAIL", "DEMO_USER_PASSWORD" ].each do |key|
      original_value = ENV.fetch(key)

      [ nil, "", "   " ].each do |value|
        ENV[key] = value
        @task.reenable

        output, errors = capture_io do
          assert_no_difference "User.count" do
            error = assert_raises(SystemExit) { @task.invoke }
            assert_equal 1, error.status
          end
        end

        assert_empty output
        assert_includes errors, "Set DEMO_USER_EMAIL and DEMO_USER_PASSWORD"
        assert_not_includes output + errors, "demo-password-123"
      end

      ENV[key] = original_value
    end
  end

  test "does not overwrite an existing user or print either password" do
    user = User.create!(email: "demo@example.test", password: "original-password-123")
    original_attributes = user.attributes
    ENV["DEMO_USER_EMAIL"] = "  DEMO@EXAMPLE.TEST  "

    output, errors = capture_io do
      assert_no_difference "User.count" do
        error = assert_raises(SystemExit) { @task.invoke }
        assert_equal 1, error.status
      end
    end

    assert_equal original_attributes, user.reload.attributes
    assert user.authenticate("original-password-123")
    assert_not user.authenticate(ENV.fetch("DEMO_USER_PASSWORD"))
    assert_empty output
    assert_includes errors, "User already exists; credentials were not changed"
    assert_not_includes output + errors, "original-password-123"
    assert_not_includes output + errors, ENV.fetch("DEMO_USER_PASSWORD")
  end

  test "does not persist invalid credentials or print the password on failure" do
    ENV["DEMO_USER_PASSWORD"] = "short-key"

    output, errors = capture_io do
      assert_no_difference "User.count" do
        error = assert_raises(SystemExit) { @task.invoke }
        assert_equal 1, error.status
      end
    end

    assert_empty output
    assert_includes errors, "Invalid demo user:"
    assert_not_includes output + errors, ENV.fetch("DEMO_USER_PASSWORD")
  end
end
