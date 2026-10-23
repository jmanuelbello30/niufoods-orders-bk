module ApiAuthenticationHelper
  def self.included(base)
    base.teardown { @api_auth_user&.destroy! }
  end

  def api_auth_headers
    @api_auth_headers ||= begin
      @api_auth_user = User.create!(email: "orders@example.test", password: "Fictional-password-123")
      _session, token = ApiSession.issue(@api_auth_user)
      { "Authorization" => "Bearer #{token}" }
    end
  end
end
