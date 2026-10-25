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

  test "requires credentials when both environment variables are missing or blank" do
    [ nil, "", "   " ].product([ nil, "", "   " ]).each do |email, password|
      ENV["DEMO_USER_EMAIL"] = email
      ENV["DEMO_USER_PASSWORD"] = password
      @task.reenable

      output, errors = capture_io do
        assert_no_difference "User.count" do
          error = assert_raises(SystemExit) { @task.invoke }
          assert_equal 1, error.status
        end
      end

      assert_empty output
      assert_equal "Set DEMO_USER_EMAIL and DEMO_USER_PASSWORD\n", errors
    end
  end

  test "normalizes the email when creating a user" do
    ENV["DEMO_USER_EMAIL"] = "  DEMO@EXAMPLE.TEST  "

    output, errors = capture_io do
      assert_difference "User.count", 1 do
        @task.invoke
      end
    end

    user = User.find_by!(email: "demo@example.test")
    assert_equal "demo@example.test", user.email
    assert user.authenticate(ENV.fetch("DEMO_USER_PASSWORD"))
    assert_equal "Demo user provisioned\n", output
    assert_empty errors
    assert_not_includes output + errors, ENV.fetch("DEMO_USER_PASSWORD")
  end

  test "rejects invalid email and passwords outside the model limits" do
    [
      [ "invalid-email", "demo-password-123", "Email" ],
      [ "demo@example.test", "a" * 11, "Password" ],
      [ "demo@example.test", "a" * 73, "Password" ],
      [ "demo@example.test", "\u00e9" * 36 + "a", "Password" ]
    ].each do |email, password, field|
      ENV["DEMO_USER_EMAIL"] = email
      ENV["DEMO_USER_PASSWORD"] = password
      @task.reenable

      output, errors = capture_io do
        assert_no_difference "User.count" do
          error = assert_raises(SystemExit) { @task.invoke }
          assert_equal 1, error.status
        end
      end

      assert_empty output
      assert_includes errors, "Invalid demo user:"
      assert_includes errors, field
      assert_not_includes output + errors, password
    end
  end

  test "accepts passwords at the minimum character and maximum byte limits" do
    [ "a" * 12, "a" * 72, "\u00e9" * 36 ].each_with_index do |password, index|
      ENV["DEMO_USER_EMAIL"] = "demo-limit-#{index}@example.test"
      ENV["DEMO_USER_PASSWORD"] = password
      @task.reenable

      output, errors = capture_io do
        assert_difference "User.count", 1 do
          @task.invoke
        end
      end

      assert User.find_by!(email: ENV.fetch("DEMO_USER_EMAIL")).authenticate(password)
      assert_equal "Demo user provisioned\n", output
      assert_empty errors
      assert_not_includes output + errors, password
    end
  end

  test "permits development without changing the database connection" do
    with_rails_environment("development") do
      output, errors = capture_io do
        assert_difference "User.count", 1 do
          @task.invoke
        end
      end

      assert User.find_by!(email: ENV.fetch("DEMO_USER_EMAIL")).authenticate(ENV.fetch("DEMO_USER_PASSWORD"))
      assert_equal "Demo user provisioned\n", output
      assert_empty errors
      assert_not_includes output + errors, ENV.fetch("DEMO_USER_PASSWORD")
    end
  end

  test "rejects production and unknown environments before checking credentials without writing" do
    [ "production", "staging" ].each do |environment|
      [ [ "demo@example.test", "demo-password-123" ], [ nil, nil ] ].each do |email, password|
        ENV["DEMO_USER_EMAIL"] = email
        ENV["DEMO_USER_PASSWORD"] = password
        @task.reenable
        original_users = User.order(:id).map(&:attributes)

        with_rails_environment(environment) do
          output, errors = capture_io do
            assert_no_difference "User.count" do
              error = assert_raises(SystemExit) { @task.invoke }
              assert_equal 1, error.status
            end
          end

          assert_empty output
          assert_equal "Demo users can only be provisioned in development or test\n", errors
          assert_not_includes output + errors, password if password
        end

        assert_equal original_users, User.order(:id).map(&:attributes)
      end
    end
  end

  private

  def with_rails_environment(environment)
    original = Rails.method(:env)
    Rails.define_singleton_method(:env) { ActiveSupport::EnvironmentInquirer.new(environment) }
    yield
  ensure
    Rails.define_singleton_method(:env, original) if original
  end
end
