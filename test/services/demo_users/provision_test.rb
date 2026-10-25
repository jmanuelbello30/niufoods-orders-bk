require "test_helper"

class DemoUsers::ProvisionTest < ActiveSupport::TestCase
  test "validates normalized credentials without saving a user" do
    provision = DemoUsers::Provision.new(email: "  DEMO@EXAMPLE.TEST  ", password: "demo-password-123")
    original_users = User.order(:id).map(&:attributes)

    assert_no_difference "User.count" do
      assert_same provision, provision.validate!
    end

    assert_equal original_users, User.order(:id).map(&:attributes)
  end

  test "creates a user with normalized email and the supplied password" do
    provision = DemoUsers::Provision.new(email: "  DEMO@EXAMPLE.TEST  ", password: "demo-password-123")

    assert_difference "User.count", 1 do
      assert_equal :created, provision.call
    end

    user = User.find_by!(email: "demo@example.test")
    assert_equal "demo@example.test", user.email
    assert user.authenticate("demo-password-123")
  end

  test "rejects an existing user by default without changing credentials" do
    user = User.create!(email: "demo@example.test", password: "original-password-123")
    original_attributes = user.attributes
    provision = DemoUsers::Provision.new(email: "  DEMO@EXAMPLE.TEST  ", password: "replacement-password-123")

    assert_no_difference "User.count" do
      error = assert_raises(DemoUsers::Provision::Error) { provision.call }
      assert_equal "User already exists; credentials were not changed", error.message
    end

    assert_equal original_attributes, user.reload.attributes
    assert user.authenticate("original-password-123")
    assert_not user.authenticate("replacement-password-123")
  end

  test "allows an existing user without saving or replacing its credentials" do
    user = User.create!(email: "demo@example.test", password: "original-password-123")
    original_attributes = user.attributes
    provision = DemoUsers::Provision.new(
      email: "  DEMO@EXAMPLE.TEST  ", password: "replacement-password-123", allow_existing: true
    )

    assert_no_difference "User.count" do
      assert_same provision, provision.validate!
      assert_equal original_attributes, user.reload.attributes
      assert_equal :existing, provision.call
    end

    assert_equal original_attributes, user.reload.attributes
    assert user.authenticate("original-password-123")
    assert_not user.authenticate("replacement-password-123")
  end

  test "validates the supplied password even when preserving an existing user" do
    user = User.create!(email: "demo@example.test", password: "original-password-123")
    original_attributes = user.attributes

    [ nil, "", "   ", "a" * 11, "a" * 73, "\u00e9" * 36 + "a" ].each do |password|
      provision = DemoUsers::Provision.new(email: user.email, password: password, allow_existing: true)

      [ :validate!, :call ].each do |operation|
        assert_no_difference "User.count" do
          error = assert_raises(DemoUsers::Provision::Error) { provision.public_send(operation) }
          if password.blank?
            assert_equal "Set DEMO_USER_EMAIL and DEMO_USER_PASSWORD", error.message
          else
            assert_includes error.message, "Invalid demo user:"
            assert_includes error.message, "Password"
            assert_not_includes error.message, password
          end
        end

        assert_equal original_attributes, user.reload.attributes
        assert user.authenticate("original-password-123")
      end
    end
  end

  test "revalidates existing users at call time after successful validation" do
    provision = DemoUsers::Provision.new(email: "demo@example.test", password: "demo-password-123")
    provision.validate!
    user = User.create!(email: "demo@example.test", password: "original-password-123")
    original_attributes = user.attributes

    assert_no_difference "User.count" do
      error = assert_raises(DemoUsers::Provision::Error) { provision.call }
      assert_equal "User already exists; credentials were not changed", error.message
    end

    assert_equal original_attributes, user.reload.attributes
  end

  test "revalidates the environment at call time without changing the database connection" do
    provision = DemoUsers::Provision.new(email: "demo@example.test", password: "demo-password-123")
    provision.validate!
    original_users = User.order(:id).map(&:attributes)
    original_env = Rails.method(:env)

    [ "production", "staging" ].each do |environment|
      Rails.define_singleton_method(:env) { ActiveSupport::EnvironmentInquirer.new(environment) }

      assert_no_difference "User.count" do
        error = assert_raises(DemoUsers::Provision::Error) { provision.call }
        assert_equal "Demo users can only be provisioned in development or test", error.message
      end

      assert_equal original_users, User.order(:id).map(&:attributes)
    end
  ensure
    Rails.define_singleton_method(:env, original_env) if original_env
  end
end
