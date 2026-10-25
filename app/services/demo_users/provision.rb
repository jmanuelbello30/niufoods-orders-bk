module DemoUsers
  class Provision
    class Error < StandardError; end

    def initialize(email:, password:, allow_existing: false)
      @email = email
      @password = password
      @allow_existing = allow_existing
    end

    def validate!
      unless Rails.env.development? || Rails.env.test?
        raise Error, "Demo users can only be provisioned in development or test"
      end
      if @email.blank? || @password.blank?
        raise Error, "Set DEMO_USER_EMAIL and DEMO_USER_PASSWORD"
      end

      @user = User.new(email: @email, password: @password)
      @existing_user = User.find_by(email: @user.email)
      if @existing_user && !@allow_existing
        raise Error, "User already exists; credentials were not changed"
      end

      @user.valid?
      # Preserving an existing user allows its email, but still validates the supplied credentials.
      @user.errors.delete(:email, :taken) if @existing_user
      if @user.errors.any?
        raise Error, "Invalid demo user: #{@user.errors.full_messages.join(', ')}"
      end

      self
    end

    def call
      validate!
      return :existing if @existing_user

      @user.save!
      :created
    rescue ActiveRecord::RecordInvalid => error
      raise Error, "Invalid demo user: #{error.record.errors.full_messages.join(', ')}"
    end
  end
end
