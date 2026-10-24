require "test_helper"
require "openapi_parser"
require "yaml"
require_relative "../support/api_authentication_helper"
require_relative "../support/http_transport_helper"

class OpenapiContractTest < ActionDispatch::IntegrationTest
  include ApiAuthenticationHelper
  include HttpTransportHelper

  # Dispatch requires a committed order, outside the test transaction.
  self.use_transactional_tests = false

  DOCUMENT = YAML.safe_load_file(Rails.root.join("openapi/v1/openapi.yaml"))
  SCHEMA = OpenAPIParser.parse(DOCUMENT, strict_reference_validation: true)
  ORDERS_PATH = "/api/v1/orders"
  LOGIN_PATH = "/api/v1/auth/login"
  BUSINESS_EXAMPLES = %w[mismatch missing_delivery_address unknown_restaurant unknown_product
    empty_items invalid_quantity duplicate_product invalid_order_type incomplete_customer].freeze
  EXPECTED_ERRORS = {
    "invalid_credentials" => { "errors" => [
      { "field" => "base", "code" => "invalid_credentials", "message" => "Invalid email or password" }
    ] },
    "invalid_json" => { "errors" => [
      { "field" => "base", "code" => "invalid_json", "message" => "Malformed JSON body" }
    ] },
    "rate_limit_exceeded" => { "errors" => [
      { "field" => "base", "code" => "rate_limit_exceeded", "message" => "Too many login attempts" }
    ] },
    "unauthenticated" => { "errors" => [
      { "field" => "base", "code" => "unauthenticated", "message" => "Valid Bearer token required" }
    ] },
    "mismatch" => { "errors" => [
      { "field" => "client_total_amount", "code" => "total_mismatch",
        "message" => "Declared total 22000 CLP does not match calculated total 22470 CLP" }
    ] },
    "missing_delivery_address" => { "errors" => [
      { "field" => "delivery_address", "code" => "blank", "message" => "can't be blank" }
    ] },
    "unknown_restaurant" => { "errors" => [
      { "field" => "restaurant_id", "code" => "blank", "message" => "must exist" }
    ] },
    "unknown_product" => { "errors" => [
      { "field" => "items", "code" => "invalid", "message" => "is invalid" },
      { "field" => "items[0].product_id", "code" => "blank", "message" => "must exist" },
      { "field" => "items[0].unit_price", "code" => "blank", "message" => "can't be blank" },
      { "field" => "items[0].unit_price", "code" => "not_a_number", "message" => "is not a number" }
    ] },
    "empty_items" => { "errors" => [
      { "field" => "items", "code" => "blank", "message" => "can't be blank" }
    ] },
    "invalid_quantity" => { "errors" => [
      { "field" => "items", "code" => "invalid", "message" => "is invalid" },
      { "field" => "items[0].quantity", "code" => "greater_than", "message" => "must be greater than 0" }
    ] },
    "duplicate_product" => { "errors" => [
      { "field" => "items", "code" => "invalid", "message" => "must not contain duplicate products" }
    ] },
    "invalid_order_type" => { "errors" => [
      { "field" => "order_type", "code" => "inclusion", "message" => "is not included in the list" }
    ] },
    "incomplete_customer" => { "errors" => [
      { "field" => "customer.name", "code" => "blank", "message" => "can't be blank" },
      { "field" => "customer.phone", "code" => "blank", "message" => "can't be blank" }
    ] },
    "invalid_structure" => { "errors" => [
      { "field" => "base", "code" => "invalid_structure", "message" => "must be a JSON object" }
    ] },
    "invalid_customer_structure" => { "errors" => [
      { "field" => "customer", "code" => "invalid_structure", "message" => "must be a JSON object" }
    ] },
    "invalid_items_structure" => { "errors" => [
      { "field" => "items", "code" => "invalid_structure", "message" => "must be an Array" }
    ] },
    "invalid_item_structure" => { "errors" => [
      { "field" => "items[0]", "code" => "invalid_structure", "message" => "must be a JSON object" }
    ] },
    "invalid_scalar_structure" => { "errors" => [
      { "field" => "items[0].quantity", "code" => "invalid_structure", "message" => "must be a scalar value" }
    ] },
    "invalid_order_type_structure" => { "errors" => [
      { "field" => "order_type", "code" => "invalid_structure", "message" => "must be a String" }
    ] }
  }.freeze

  setup do
    @created_order_ids = []
    @store_requests = []
    assert Rails.env.test?
    assert_match(/\Aniufoods_orders_test(?:_\d+)?\z/,
      ActiveRecord::Base.connection.select_value("SELECT current_database()"))
    load Rails.root.join("db/seeds.rb")
    @headers = api_auth_headers
    @credentials = DOCUMENT.fetch("paths").fetch(LOGIN_PATH).fetch("post")
      .fetch("requestBody").fetch("content").fetch("application/json").fetch("example").deep_dup
    @api_auth_user.update!(email: @credentials.fetch("email"), password: @credentials.fetch("password"))
    @transport = ->(_http, request) do
      assert_nil request["Authorization"], "User credentials must not be forwarded to the store"
      assert_not Order.connection.transaction_open?
      body = JSON.parse(request.body)
      @created_order_ids << body.fetch("order_id")
      @store_requests << body
      raise Errno::ECONNREFUSED if @transport_error

      http_response(200, JSON.generate(data: {
        accepted: true, order_id: body.fetch("order_id"),
        restaurant_id: body.fetch("restaurant_id"), duplicate: false
      }))
    end
  end

  teardown do
    OrderItem.where(order_id: @created_order_ids).delete_all
    Order.where(id: @created_order_ids).delete_all
  end

  BUSINESS_EXAMPLES.each do |name|
    test "rejects the documented #{name} request without persistence or dispatch" do
      assert_rejected_order(order_example(name), name)
    end
  end

  test "rejects structural violations with the exact expected responses" do
    payload = order_example("pickup_simple")
    examples = {
      "invalid_structure" => [],
      "invalid_customer_structure" => payload.merge("customer" => []),
      "invalid_items_structure" => payload.merge("items" => {}),
      "invalid_item_structure" => payload.merge("items" => [ nil ]),
      "invalid_scalar_structure" => payload.merge("items" => [ { "product_id" => 1, "quantity" => [] } ]),
      "invalid_order_type_structure" => payload.merge("order_type" => 0)
    }

    examples.each do |name, body|
      assert_rejected_order(body, name)
    end
  end

  %w[pickup_simple delivery_multiple matching_total].each do |name|
    test "creates the documented #{name} request with historical catalog prices" do
      payload = order_example(name)
      order = create_order(payload)
      assert_created_order(order, payload, "sent")

      assert_order_sample(order) if name == "pickup_simple"
      assert_predicate order, :sent?
      assert_not_nil order.dispatched_at
      assert_nil order.last_dispatch_error

      prices = order.order_items.to_h { |item| [ item.product_id, item.unit_price ] }
      Product.find(prices.keys).each { |product| product.update!(price: product.price + 1) }
      assert_equal prices, order.reload.order_items.to_h { |item| [ item.product_id, item.unit_price ] }
      assert_equal response.parsed_body.dig("data", "total_amount"), order.total_amount
    ensure
      prices&.each { |id, price| Product.find(id).update!(price: price) }
    end
  end

  test "keeps a created order after a transport failure and matches dispatch error" do
    @transport_error = true
    payload = order_example("pickup_simple")
    order = create_order(payload)

    assert_created_order(order, payload, "error")
    assert_predicate order, :error?
    assert_nil order.dispatched_at
    assert_equal "Dispatch transport failed (Errno::ECONNREFUSED)", order.last_dispatch_error
  end

  test "public login accepts the documented fictional credentials and response shape" do
    assert_difference "ApiSession.count", 1 do
      post_contract(LOGIN_PATH, @credentials, headers: {})
    end
    assert_contract_response(LOGIN_PATH, 200)
    data = response.parsed_body.fetch("data")
    assert data.fetch("access_token").match?(/\A[0-9a-f]{64}\z/), "Expected an opaque token"
    assert_equal @api_auth_user.id, data.fetch("user").fetch("id")
    assert_equal ApiSession.order(:id).last.expires_at.iso8601(3), data.fetch("expires_at")
    expected = response_content(LOGIN_PATH, 200).fetch("example").deep_dup
    actual = response.parsed_body.deep_dup
    actual.fetch("data")["access_token"] = expected.dig("data", "access_token")
    actual.fetch("data")["expires_at"] = expected.dig("data", "expires_at")
    actual.fetch("data").fetch("user")["id"] = expected.dig("data", "user", "id")
    assert_equal expected, actual
  end

  test "public login rejects invalid credentials with the exact expected response" do
    assert_no_difference "ApiSession.count" do
      post_contract(LOGIN_PATH, @credentials.merge("password" => "wrong-password"), headers: {})
    end
    assert_contract_response(LOGIN_PATH, 401)
    assert_equal expected_errors("invalid_credentials"), response.parsed_body
  end

  test "public login rejects malformed JSON with the exact expected response" do
    assert_no_difference "ApiSession.count" do
      post_contract(LOGIN_PATH, "{", headers: {}, raw: true)
    end
    assert_contract_response(LOGIN_PATH, 400)
    assert_equal expected_errors("invalid_json"), response.parsed_body
  end

  test "public login rate limit matches the exact expected response without retry after" do
    # Replace only the backing store, keeping the native Rails limiter active.
    store = Api::V1::AuthController.cache_store
    memory_store = ActiveSupport::Cache::MemoryStore.new
    store.singleton_class.define_method(:increment) do |*args, **options|
      memory_store.increment(*args, **options)
    end

    assert_no_difference "ApiSession.count" do
      10.times do
        post_contract(LOGIN_PATH, @credentials.merge("password" => "wrong-password"), headers: {})
        assert_contract_response(LOGIN_PATH, 401)
        assert_equal expected_errors("invalid_credentials"), response.parsed_body
      end
      post_contract(LOGIN_PATH, @credentials, headers: {})
    end
    assert_contract_response(LOGIN_PATH, 429)
    assert_equal expected_errors("rate_limit_exceeded"), response.parsed_body
    assert_nil response.headers["Retry-After"]
  ensure
    store.singleton_class.remove_method(:increment)
  end

  test "orders require bearer authentication before parsing malformed JSON" do
    [ JSON.generate(order_example("pickup_simple")), "{" ].each do |body|
      assert_no_difference [ "Order.count", "OrderItem.count", -> { @store_requests.size } ] do
        post_contract(ORDERS_PATH, body, headers: {}, raw: true)
      end
      assert_contract_response(ORDERS_PATH, 401)
      assert_equal expected_errors("unauthenticated"), response.parsed_body
      assert_equal "Bearer", response.headers["WWW-Authenticate"]
    end

    [ "{", "" ].each do |body|
      assert_no_difference [ "Order.count", "OrderItem.count", -> { @store_requests.size } ] do
        post_contract(ORDERS_PATH, body, raw: true)
      end
      assert_contract_response(ORDERS_PATH, 400)
      assert_equal expected_errors("invalid_json"), response.parsed_body
    end
  end

  private
    def order_example(name)
      DOCUMENT.fetch("paths").fetch(ORDERS_PATH).fetch("post").fetch("requestBody")
        .fetch("content").fetch("application/json").fetch("examples").fetch(name).fetch("value").deep_dup
    end

    def response_content(path, status)
      definition = DOCUMENT.fetch("paths").fetch(path).fetch("post").fetch("responses").fetch(status.to_s)
      definition.fetch("content").fetch("application/json")
    end

    def expected_errors(name)
      EXPECTED_ERRORS.fetch(name)
    end

    def post_contract(path, payload, headers: @headers, raw: false)
      with_http_transport(@transport) do
        post path, params: raw ? payload.dup : JSON.generate(payload),
          headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }.merge(headers)
      end
    ensure
      if path == ORDERS_PATH && response&.status == 201
        @created_order_ids << response.parsed_body.fetch("data").fetch("id")
      end
    end

    def assert_contract_response(path, status)
      assert_response status
      assert_equal "application/json", response.media_type
      assert_equal "no-store", response.headers["Cache-Control"]
      return unless [ 200, 201 ].include?(status)

      body = OpenAPIParser::RequestOperation::ValidatableResponseBody.new(
        response.status, response.parsed_body, response.headers.to_h
      )
      SCHEMA.request_operation(:post, path).validate_response_body(body)
    end

    def assert_rejected_order(payload, name)
      assert_no_difference [ "Order.count", "OrderItem.count", -> { @store_requests.size } ] do
        post_contract(ORDERS_PATH, payload)
      end
      assert_contract_response(ORDERS_PATH, 422)
      assert_equal expected_errors(name), response.parsed_body
    end

    def create_order(payload)
      assert_difference "Order.count", 1 do
        assert_difference "OrderItem.count", payload.fetch("items").size do
          assert_difference -> { @store_requests.size }, 1 do
            post_contract(ORDERS_PATH, payload)
          end
        end
      end
      assert_contract_response(ORDERS_PATH, 201)
      Order.find(response.parsed_body.fetch("data").fetch("id"))
    end

    def assert_created_order(order, payload, status)
      items = payload.fetch("items").map do |item|
        item.merge("unit_price" => Product.find(item.fetch("product_id")).price)
      end
      total = items.sum { |item| item.fetch("quantity") * item.fetch("unit_price") }
      assert_equal({ "data" => {
        "id" => order.id, "restaurant_id" => payload.fetch("restaurant_id"),
        "order_type" => payload.fetch("order_type"), "total_amount" => total,
        "dispatch_status" => status,
        "created_at" => order.created_at.iso8601(3)
      } }, response.parsed_body)
      assert_not response.parsed_body.fetch("data").key?("client_total_amount")
      if payload["client_total_amount"].nil?
        assert_nil order.reload.client_total_amount
      else
        assert_equal payload.fetch("client_total_amount"), order.reload.client_total_amount
      end
      assert_equal total, order.total_amount
      assert_equal payload.fetch("customer").values_at("name", "phone"), [ order.customer_name, order.customer_phone ]
      if payload["delivery_address"].nil?
        assert_nil order.delivery_address
      else
        assert_equal payload.fetch("delivery_address"), order.delivery_address
      end
      assert_equal items, order.order_items.order(:id).as_json(only: %w[product_id quantity unit_price])
      assert_equal items, @store_requests.sole.fetch("items")
      assert_equal total, @store_requests.sole.fetch("total_amount")
    end

    def assert_order_sample(order)
      expected = response_content(ORDERS_PATH, 201).fetch("example").deep_dup
      expected.fetch("data").merge!("id" => order.id, "created_at" => order.created_at.iso8601(3))
      assert_equal expected, response.parsed_body
    end
end
