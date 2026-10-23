class User < ApplicationRecord
  has_secure_password reset_token: false

  has_many :api_sessions, dependent: :destroy

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }, uniqueness: true
  validates :password, length: { minimum: 12 }, allow_nil: true
end
