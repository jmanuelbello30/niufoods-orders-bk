module Api
  module V1
    class AuthController < ApplicationController
      wrap_parameters false
      skip_before_action :authenticate_api_session, only: :login

      rate_limit to: 10, within: 1.minute, only: :login, with: :render_rate_limit
      rescue_from ActionDispatch::Http::Parameters::ParseError, with: :render_invalid_json

      def login
        credentials = request.request_parameters.slice("email", "password")
        user = if credentials["email"].is_a?(String) && credentials["password"].is_a?(String) &&
            credentials["password"].bytesize <= 72 && !credentials["password"].include?("\0")
          User.authenticate_by(email: credentials["email"], password: credentials["password"])
        end
        unless user
          return render json: { errors: [ { field: "base", code: "invalid_credentials", message: "Invalid email or password" } ] },
            status: :unauthorized
        end

        session, token = ApiSession.issue(user)
        render json: { data: { access_token: token, token_type: "Bearer", expires_at: session.expires_at.iso8601(3),
          user: user.as_json(only: %i[id email]) } }
      end

      def me
        render json: { data: @current_api_session.user.as_json(only: %i[id email]) }
      end

      def logout
        @current_api_session.destroy!
        head :no_content
      end

      private
        def process_action(action, *)
          response.headers["Cache-Control"] = "no-store"
          if action == "login"
            # Rails logs raw malformed JSON before parameter filtering; never log a login body.
            request.define_singleton_method(:log_parse_error_once) { logger&.debug("Malformed login JSON body") }
            request.set_header("action_dispatch.parameter_filter", [ /./ ])
          end
          super
        end

        def render_rate_limit
          render json: { errors: [ { field: "base", code: "rate_limit_exceeded", message: "Too many login attempts" } ] },
            status: :too_many_requests
        end

        def render_invalid_json
          render json: { errors: [ { field: "base", code: "invalid_json", message: "Malformed JSON body" } ] },
            status: :bad_request
        end
    end
  end
end
