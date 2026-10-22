require "uri"

class Restaurant < ApplicationRecord
  validates :name, :code, :dispatch_url, presence: true
  validates :code, uniqueness: true
  validate :dispatch_url_must_be_http_with_host

  private
    def dispatch_url_must_be_http_with_host
      return if dispatch_url.blank?

      uri = URI.parse(dispatch_url)
      unless uri.is_a?(URI::HTTP) && uri.host.present?
        errors.add(:dispatch_url, "must be an HTTP or HTTPS URL with a host")
      end
    rescue URI::InvalidURIError
      errors.add(:dispatch_url, "must be an HTTP or HTTPS URL with a host")
    end
end
