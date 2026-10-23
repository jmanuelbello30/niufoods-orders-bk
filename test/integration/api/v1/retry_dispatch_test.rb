require "test_helper"
require_relative "../../../support/api_authentication_helper"
require_relative "../../../support/http_transport_helper"

class Api::V1::RetryDispatchTest < ActionDispatch::IntegrationTest
  include ApiAuthenticationHelper
  include HttpTransportHelper

  # Dispatch must run outside a test transaction, after the order is committed.
  self.use_transactional_tests = false

  setup do
    @api_auth_headers = api_auth_headers
    @order = Order.new(
      restaurant: restaurants(:one), order_type: :delivery,
      customer_name: "Test Customer", customer_phone: "+56000000000",
      delivery_address: "Test Street 123", total_amount: 2460, client_total_amount: 2460,
      dispatch_status: :error, last_dispatch_error: "Previous failure", dispatched_at: 1.day.ago
    )
    @order.order_items.build(product: products(:one), quantity: 2, unit_price: 1230)
    @order.save!
    @requests = []
    @transport = ->(_http, _request) do
      http_response(200, JSON.generate(data: {
        accepted: true, order_id: @order.id, restaurant_id: @order.restaurant_id
      }))
    end
  end

  teardown do
    if @order&.id
      OrderItem.where(order_id: @order.id).delete_all
      Order.where(id: @order.id).delete_all
    end
  end

  test "retries an errored order and clears its previous error and timestamp" do
    previous_time = @order.dispatched_at
    freeze_time do
      post_retry
      assert_dispatch_response("sent")

      assert_equal Time.current, @order.dispatched_at
      assert_not_equal previous_time, @order.dispatched_at
      assert_nil @order.last_dispatch_error
    end
  end

  test "retries a pending order without a request body" do
    @order.update!(dispatch_status: :pending, last_dispatch_error: nil, dispatched_at: nil)

    post_retry

    assert_dispatch_response("sent")
    assert_predicate @order.dispatched_at, :present?
    assert_nil @order.last_dispatch_error
  end

  test "returns HTTP 200 and replaces the previous error when the store returns HTTP 503" do
    @transport = ->(_http, _request) do
      http_response(503, JSON.generate(errors: [ { message: "Private store failure" } ]))
    end

    post_retry

    assert_dispatch_response("error")
    assert_equal "Store returned HTTP 503", @order.last_dispatch_error
    assert_nil @order.dispatched_at
    assert_nil response.parsed_body.dig("data", "dispatched_at")
  end

  test "accepts a duplicate acknowledgment for the same order and restaurant" do
    @transport = ->(_http, _request) do
      http_response(200, JSON.generate(data: {
        accepted: true, order_id: @order.id, restaurant_id: @order.restaurant_id, duplicate: true
      }))
    end

    post_retry

    assert_dispatch_response("sent")
    assert_predicate @order.dispatched_at, :present?
    assert_nil @order.last_dispatch_error
  end

  test "rejects an already sent order without HTTP or changes to any persisted attribute" do
    @order.update!(dispatch_status: :sent, dispatched_at: Time.current, last_dispatch_error: nil)
    before = @order.attributes

    post_retry

    assert_error_response(:conflict, "dispatch_status", "already_sent", "Order has already been sent")
    assert_equal before, @order.reload.attributes
  end

  test "returns not found for a nonexistent order without HTTP or persisted changes" do
    before = @order.attributes

    post_retry(id: -1)

    assert_error_response(:not_found, "id", "not_found", "Order not found")
    assert_equal before, @order.reload.attributes
  end

  test "ignores body identifiers destinations customer items amounts and dispatch attributes" do
    payload = {
      id: -1, order_id: -1, restaurant_id: restaurants(:two).id,
      dispatch_url: "https://ignored.example/orders", order_type: "pickup",
      customer: { name: "Injected Customer", phone: "Injected phone" },
      customer_name: "Injected name", customer_phone: "Injected phone", delivery_address: "Injected address",
      items: [ { product_id: products(:two).id, quantity: 99, unit_price: 1, order_id: -1 } ],
      quantity: 99, unit_price: 1, total_amount: 1, client_total_amount: 1,
      dispatch_status: "sent", last_dispatch_error: "Injected error",
      created_at: "2000-01-01T00:00:00Z", updated_at: "2000-01-01T00:00:00Z",
      dispatched_at: "2000-01-01T00:00:00Z"
    }

    post_retry(payload: payload)

    assert_dispatch_response("sent")
    assert_nil @order.last_dispatch_error
    assert_not_equal Time.iso8601(payload[:dispatched_at]), @order.dispatched_at
  end

  test "sends historical item prices and totals after the catalog price changes" do
    products(:one).update!(price: 9999)
    catalog = products(:one).attributes

    post_retry

    assert_dispatch_response("sent")
    assert_equal catalog, products(:one).reload.attributes
    assert_equal 2460, @order.total_amount
    assert_equal 1230, @order.order_items.sole.unit_price
  end

  test "propagates programming errors without changing persisted state" do
    before = @order.attributes
    items = @order.order_items.order(:id).map(&:attributes)
    @transport = ->(_http, _request) { raise NoMethodError, "Unexpected programming failure" }

    error = nil
    assert_no_difference [ -> { Order.count }, -> { OrderItem.count } ] do
      error = assert_raises(NoMethodError) { post_retry }
    end

    assert_equal "Unexpected programming failure", error.message
    assert_equal 1, @requests.size
    assert_equal before, @order.reload.attributes
    assert_equal items, @order.order_items.order(:id).map(&:attributes)
  end

  private
    def post_retry(id: @order.id, payload: nil)
      counts = [ Order.count, OrderItem.count ]
      before = @order.reload.attributes.except("dispatch_status", "last_dispatch_error", "dispatched_at", "updated_at")
      items = @order.order_items.order(:id).map(&:attributes)
      expected_payload = {
        "order_id" => @order.id, "restaurant_id" => @order.restaurant_id, "order_type" => @order.order_type,
        "customer" => { "name" => @order.customer_name, "phone" => @order.customer_phone },
        "delivery_address" => @order.delivery_address, "total_amount" => @order.total_amount,
        "items" => items.map { |item| item.slice("product_id", "quantity", "unit_price") }
      }
      destination = URI.parse(@order.restaurant.dispatch_url)
      handler = lambda do |http, request|
        @requests << [ http, request ]
        assert_not Order.connection.transaction_open?
        assert_instance_of Net::HTTP::Post, request
        assert_equal destination.hostname, http.address
        assert_equal destination.port, http.port
        assert_equal destination.scheme == "https", http.use_ssl?
        assert_equal destination.request_uri, request.path
        assert_equal "application/json", request["Content-Type"]
        assert_equal "application/json", request["Accept"]
        assert_nil request["Authorization"], "User credentials must not be forwarded to the store"
        assert_equal expected_payload, JSON.parse(request.body)
        @transport.call(http, request)
      end
      with_http_transport(handler) do
        post "/api/v1/orders/#{id}/retry_dispatch", params: payload.nil? ? nil : JSON.generate(payload),
          headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }.merge(@api_auth_headers)
      end
      assert_equal counts, [ Order.count, OrderItem.count ]
      assert_equal before, @order.reload.attributes.slice(*before.keys)
      assert_equal items, @order.order_items.order(:id).map(&:attributes)
    end

    def assert_dispatch_response(status)
      assert_response :ok
      assert_equal "application/json", response.media_type
      assert_equal [ "data" ], response.parsed_body.keys
      data = response.parsed_body.fetch("data")
      assert_equal %w[client_total_amount created_at dispatch_status dispatched_at id last_dispatch_error
        order_type restaurant_id total_amount], data.keys.sort
      assert_equal @order.as_json(only: data.keys), data
      assert_equal status, data.fetch("dispatch_status")
      assert_kind_of String, data.fetch("created_at")
      assert_kind_of String, data.fetch("dispatched_at") if status == "sent"
      assert_equal 1, @requests.size
    end

    def assert_error_response(status, field, code, message)
      assert_response status
      assert_equal "application/json", response.media_type
      assert_equal({ "errors" => [ { "field" => field, "code" => code, "message" => message } ] }, response.parsed_body)
      response.parsed_body.fetch("errors").each do |error|
        error.each_value { |value| assert_kind_of String, value }
      end
      assert_empty @requests
    end
end
