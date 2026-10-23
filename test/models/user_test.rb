require "test_helper"

class UserTest < ActiveSupport::TestCase
  setup do
    @user = User.new(email: "user@example.test", password: "test-password-123")
  end

  test "normalizes email before persisting and looking up a user" do
    @user.email = "  USER@Example.Test  "

    assert @user.save
    assert_equal "user@example.test", @user.reload.email
    assert_equal @user, User.find_by(email: "  USER@EXAMPLE.TEST  ")
  end

  test "requires an email" do
    [ nil, "", "   " ].each do |email|
      @user.email = email

      assert_not @user.valid?
      assert @user.errors.of_kind?(:email, :blank)
    end
  end

  test "rejects malformed emails" do
    [ "user", "user@", "@example.test", "user name@example.test" ].each do |email|
      @user.email = email

      assert_not @user.valid?, "Expected #{email.inspect} to be invalid"
      assert @user.errors.of_kind?(:email, :invalid)
    end
  end

  test "requires a unique email after normalization" do
    @user.save!
    duplicate = User.new(email: "  USER@EXAMPLE.TEST  ", password: "another-password-123")

    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:email, :taken)
  end

  test "requires a password for a new user" do
    [ nil, "" ].each do |password|
      user = User.new(email: "new@example.test", password: password)

      assert_not user.valid?
      assert user.errors.of_kind?(:password, :blank)
    end
  end

  test "requires at least twelve password characters" do
    @user.password = "a" * 11

    assert_not @user.valid?
    assert @user.errors.of_kind?(:password, :too_short)

    @user.password = "a" * 12

    assert @user.valid?
  end

  test "counts multibyte password characters for the minimum length" do
    @user.password = "\u00e9" * 11

    assert_not @user.valid?
    assert @user.errors.of_kind?(:password, :too_short)

    @user.password = "\u00e9" * 12

    assert @user.valid?
  end

  test "accepts seventy two password bytes and rejects seventy three" do
    @user.password = "a" * 72
    assert @user.valid?

    @user.password = "a" * 73

    assert_not @user.valid?
    assert @user.errors.of_kind?(:password, :password_too_long)
  end

  test "applies the bcrypt byte limit to multibyte passwords" do
    @user.password = "\u00e9" * 36

    assert_equal 72, @user.password.bytesize
    assert @user.valid?

    @user.password = "\u00e9" * 36 + "a"

    assert_equal 73, @user.password.bytesize
    assert_not @user.valid?
    assert @user.errors.of_kind?(:password, :password_too_long)
  end

  test "persists a bcrypt digest instead of a plaintext password" do
    password = @user.password
    @user.save!
    persisted_user = User.find(@user.id)

    assert_nil persisted_user.password
    assert_not_equal password, persisted_user.password_digest
    assert BCrypt::Password.new(persisted_user.password_digest).is_password?(password)
    assert_equal persisted_user, persisted_user.authenticate(password)
    assert_not persisted_user.authenticate("incorrect-password")
    assert_not_includes persisted_user.attributes.values, password
  end

  test "updates a user without supplying or changing the password" do
    @user.save!
    persisted_user = User.find(@user.id)
    digest = persisted_user.password_digest

    assert_nil persisted_user.password
    assert persisted_user.update(email: "updated@example.test")
    assert_equal "updated@example.test", persisted_user.reload.email
    assert_equal digest, persisted_user.password_digest
    assert persisted_user.authenticate("test-password-123")
  end
end
