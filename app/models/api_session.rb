require "digest"

class ApiSession < ApplicationRecord
  belongs_to :user

  validates :token_digest, presence: true, uniqueness: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :expires_at, presence: true

  def self.issue(user)
    token = SecureRandom.hex(32)
    session = create!(user: user, token_digest: Digest::SHA256.hexdigest(token), expires_at: 8.hours.from_now)
    [ session, token ]
  end

  def self.authenticate(token)
    where("expires_at > ?", Time.current).find_by(token_digest: Digest::SHA256.hexdigest(token))
  end
end
