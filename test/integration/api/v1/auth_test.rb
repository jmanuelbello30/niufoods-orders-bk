require "test_helper"
require_relative "../../../support/http_transport_helper"

class Api::V1::AuthTest < ActionDispatch::IntegrationTest
  include HttpTransportHelper

  setup do
    @user = User.create!(email: "demo@example.test", password: "Fictional-password-123")
  end

  test "login returns the exact contract and stores only the digest" do
    travel_to Time.utc(2026, 10, 23, 12) do
      assert_difference "ApiSession.count", 1 do
        login(email: "  DEMO@EXAMPLE.TEST ", password: "Fictional-password-123")
      end
      assert_response :ok
      assert_equal "no-store", response.headers["Cache-Control"]
      data = response.parsed_body.fetch("data")
      assert_equal %w[access_token expires_at token_type user], data.keys.sort
      assert_match(/\A[0-9a-f]{64}\z/, data.fetch("access_token"))
      assert_equal "Bearer", data.fetch("token_type")
      assert_equal 8.hours.from_now.iso8601(3), data.fetch("expires_at")
      assert_equal({ "id" => @user.id, "email" => @user.email }, data.fetch("user"))
      session = ApiSession.order(:id).last
      assert_equal Digest::SHA256.hexdigest(data.fetch("access_token")), session.token_digest
      assert_not_includes session.attributes.values, data.fetch("access_token")
    end
  end

  test "wrong unknown absent and structured credentials have one generic response" do
    [ { email: @user.email, password: "wrong-password" },
      { email: "unknown@example.test", password: "Fictional-password-123" }, {},
      { email: @user.email }, { password: "Fictional-password-123" },
      { email: [], password: {} }, { email: @user.email, password: "" },
      { email: @user.email, password: "a" * 73 } ].each do |credentials|
      assert_no_difference "ApiSession.count" do
        login(**credentials)
      end
      assert_error :unauthorized, "invalid_credentials", "Invalid email or password"
    end
  end

  test "query credentials are not used and malformed login JSON is not cached" do
    post "/api/v1/auth/login?email=demo%40example.test&password=Fictional-password-123", params: {}, as: :json
    assert_error :unauthorized, "invalid_credentials", "Invalid email or password"
    post "/api/v1/auth/login", params: "{", headers: { "CONTENT_TYPE" => "application/json" }
    assert_error :bad_request, "invalid_json", "Malformed JSON body"
  end

  test "passwords containing null bytes have the same generic rejection for known and unknown users" do
    [ @user.email, "unknown@example.test" ].each do |email|
      assert_no_difference "ApiSession.count" do
        login(email: email, password: "invalid\u0000password")
      end
      assert_error :unauthorized, "invalid_credentials", "Invalid email or password"
    end
  end

  test "me and logout revoke only the presented session immediately" do
    first, token = ApiSession.issue(@user)
    second, other_token = ApiSession.issue(@user)
    get "/api/v1/auth/me", headers: bearer(token)
    assert_response :ok
    assert_equal({ "data" => { "id" => @user.id, "email" => @user.email } }, response.parsed_body)
    assert_equal "no-store", response.headers["Cache-Control"]

    assert_difference "ApiSession.count", -1 do
      delete "/api/v1/auth/logout", headers: bearer(token)
    end
    assert_response :no_content
    assert_empty response.body
    assert_not ApiSession.exists?(first.id)
    assert ApiSession.exists?(second.id)
    get "/api/v1/auth/me", headers: bearer(token)
    assert_unauthenticated
    get "/api/v1/auth/me", headers: bearer(other_token)
    assert_response :ok
  end

  test "missing malformed unknown and expired tokens are rejected everywhere without side effects" do
    _session, token = ApiSession.issue(@user)
    expired, expired_token = ApiSession.issue(@user)
    expired.update!(expires_at: Time.current)
    authorizations = [ nil, "", "Basic #{token}", "Bearer", "Bearer ", "Bearer unknown",
      "Bearer #{token} extra", "Bearer  #{token}", "Bearer #{token},#{token}",
      "Bearer #{'a' * 64}", "Bearer #{expired_token}" ]
    endpoints = [ [ :get, "/api/v1/auth/me" ], [ :delete, "/api/v1/auth/logout" ],
      [ :get, "/api/v1/orders" ], [ :get, "/api/v1/orders/1" ],
      [ :post, "/api/v1/orders" ], [ :post, "/api/v1/orders/1/retry_dispatch" ] ]
    with_http_transport(->(*) { flunk "Unauthorized requests must not dispatch" }) do
      authorizations.product(endpoints).each do |authorization, (method, path)|
        assert_no_difference [ "Order.count", "OrderItem.count", "ApiSession.count" ] do
          public_send(method, path, headers: { "Authorization" => authorization }.compact)
        end
        assert_unauthenticated
      end
    end
  end

  test "tokens in query body or cookies do not authenticate" do
    _session, token = ApiSession.issue(@user)
    cookies[:access_token] = token
    get "/api/v1/auth/me", params: { access_token: token, token: token }
    assert_unauthenticated
    post "/api/v1/orders", params: { access_token: token, token: token }, as: :json
    assert_unauthenticated
  end

  test "absolute expiration does not slide after use" do
    travel_to Time.utc(2026, 10, 23, 12) do
      session, token = ApiSession.issue(@user)
      original_expiration = session.expires_at
      travel 8.hours - 1.second
      get "/api/v1/auth/me", headers: bearer(token)
      assert_response :ok
      assert_equal original_expiration, session.reload.expires_at
      travel 1.second
      get "/api/v1/auth/me", headers: bearer(token)
      assert_unauthenticated
    end
  end

  test "login rate limit uses the native cache and recovers after the window" do
    # Test normally uses NullStore; replace only the backing store, not the limiter.
    store = Api::V1::AuthController.cache_store
    memory_store = ActiveSupport::Cache::MemoryStore.new
    store.singleton_class.define_method(:increment) do |*args, **options|
      memory_store.increment(*args, **options)
    end
    travel_to Time.utc(2026, 10, 23, 12) do
      10.times do
        login(email: @user.email, password: "wrong-password")
        assert_response :unauthorized
      end
      assert_no_difference "ApiSession.count" do
        login(email: @user.email, password: "Fictional-password-123")
      end
      assert_error :too_many_requests, "rate_limit_exceeded", "Too many login attempts"
      travel 61.seconds
      login(email: @user.email, password: "Fictional-password-123")
      assert_response :ok
    end
  ensure
    store.singleton_class.remove_method(:increment)
  end

  test "login logging filters the entire payload and authorization" do
    payloads = []
    subscriber = ->(event) { payloads << event.payload.fetch(:params) }
    ActiveSupport::Notifications.subscribed(subscriber, "start_processing.action_controller") do
      login(email: @user.email, password: "Fictional-password-123", extra: "private-body")
    end
    logged = payloads.to_json
    assert_not_includes logged, @user.email
    assert_not_includes logged, "Fictional-password-123"
    assert_not_includes logged, "private-body"
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter("HTTP_AUTHORIZATION" => "Bearer fictional")["HTTP_AUTHORIZATION"]
  end

  test "health remains public" do
    get "/up"
    assert_response :ok
  end

  test "malformed login JSON never logs the raw body even at debug level" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    logger.level = Logger::DEBUG
    Rails.logger.broadcast_to(logger)
    post "/api/v1/auth/login", params: '{"email":"private@example.test","password":"private-password"',
      headers: { "CONTENT_TYPE" => "application/json" }

    assert_error :bad_request, "invalid_json", "Malformed JSON body"
    assert_includes output.string, "Malformed login JSON body"
    assert_not_includes output.string, "private@example.test"
    assert_not_includes output.string, "private-password"
    assert_not_includes output.string, "Contents:"
  ensure
    Rails.logger.stop_broadcasting_to(logger)
  end

  private
    def login(**credentials)
      post "/api/v1/auth/login", params: credentials, as: :json
    end

    def bearer(token)
      { "Authorization" => "Bearer #{token}" }
    end

    def assert_unauthenticated
      assert_error :unauthorized, "unauthenticated", "Valid Bearer token required"
      assert_equal "Bearer", response.headers["WWW-Authenticate"]
    end

    def assert_error(status, code, message)
      assert_response status
      assert_equal "application/json", response.media_type
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal({ "errors" => [ { "field" => "base", "code" => code, "message" => message } ] }, response.parsed_body)
    end
end
