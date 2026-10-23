class ApplicationController < ActionController::API
  before_action :prevent_response_caching
  before_action :authenticate_api_session

  private
    def prevent_response_caching
      response.headers["Cache-Control"] = "no-store"
    end

    def authenticate_api_session
      authorization = request.get_header("HTTP_AUTHORIZATION").to_s
      token = authorization[/\ABearer ([0-9a-f]{64})\z/i, 1]
      @current_api_session = ApiSession.authenticate(token) if token
      return if @current_api_session

      response.headers["WWW-Authenticate"] = "Bearer"
      render json: { errors: [ { field: "base", code: "unauthenticated", message: "Valid Bearer token required" } ] },
        status: :unauthorized
    end
end
