require "test_helper"
require_relative "../../support/http_transport_helper"

class Orders::DispatchTest < ActiveSupport::TestCase
  include HttpTransportHelper

  self.use_transactional_tests = false

  setup do
    @order = Order.new(
      restaurant: restaurants(:one), order_type: :delivery,
      customer_name: "Test Customer", customer_phone: "+56000000000",
      delivery_address: "Test Street 123", total_amount: 2460, client_total_amount: 2460
    )
    @order.order_items.build(product: products(:one), quantity: 2, unit_price: 1230)
    @order.save!
  end

  teardown do
    if @order&.id
      OrderItem.where(order_id: @order.id).delete_all
      Order.where(id: @order.id).delete_all
    end
  end

  test "posts the exact persisted delivery payload and HTTP connection settings" do
    restaurants(:one).update!(dispatch_url: "http://localhost:4568/restaurants/TEST-ONE/orders?mode=success")
    handler = lambda do |http, request|
      assert_instance_of Net::HTTP, http
      assert_equal "localhost", http.address
      assert_equal 4568, http.port
      assert_not http.use_ssl?
      assert_not http.proxy?
      assert_nil http.proxy_address
      assert_equal [ 2, 5, 5, 0 ], [ http.open_timeout, http.read_timeout, http.write_timeout, http.max_retries ]
      assert_instance_of Net::HTTP::Post, request
      assert_equal "/restaurants/TEST-ONE/orders?mode=success", request.path
      assert_equal "application/json", request["Content-Type"]
      assert_equal "application/json", request["Accept"]
      assert_equal expected_payload, JSON.parse(request.body)
      http_response(200, confirmation.to_json)
    end

    dispatch_with(handler)

    assert @order.reload.sent?
  end

  test "uses HTTPS peer verification and sends null address for pickup" do
    @order.update!(restaurant: restaurants(:two), order_type: :pickup, delivery_address: nil)
    handler = lambda do |http, request|
      assert_equal "store.example.com", http.address
      assert_equal 443, http.port
      assert http.use_ssl?
      assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
      assert_equal [ 2, 5, 5, 0 ], [ http.open_timeout, http.read_timeout, http.write_timeout, http.max_retries ]
      assert_not http.proxy?
      assert_nil http.proxy_address
      assert_equal expected_payload.merge("order_type" => "pickup", "delivery_address" => nil), JSON.parse(request.body)
      http_response(200, confirmation.to_json)
    end

    dispatch_with(handler)
    assert @order.reload.sent?
  end

  test "reloads dirty order and items and sends historical prices despite catalog changes" do
    products(:one).update!(price: 9999)
    @order.assign_attributes(customer_name: "Unsaved Customer", total_amount: 1, dispatch_status: :sent)
    @order.order_items.load.first.assign_attributes(quantity: 9, unit_price: 1)
    handler = lambda do |_http, request|
      assert_equal expected_payload, JSON.parse(request.body)
      http_response(200, confirmation.to_json)
    end

    dispatch_with(handler)

    assert_equal 9999, products(:one).reload.price
    assert_equal [ 2, 1230 ], @order.order_items.sole.attributes.values_at("quantity", "unit_price")
  end

  test "accepts successful HTTP statuses and optional duplicate confirmations and clears stale errors" do
    freeze_time do
      [ [ 200, false ], [ 201, true ], [ 202, nil ], [ 206, nil ] ].each do |code, duplicate|
        @order.update!(dispatch_status: :error, last_dispatch_error: "Previous failure", dispatched_at: 1.day.ago)
        body = confirmation
        body[:data][:duplicate] = duplicate unless duplicate.nil?

        dispatch_with(->(_http, _request) { http_response(code, body.to_json) })

        assert @order.reload.sent?
        assert_equal Time.current, @order.dispatched_at
        assert_nil @order.last_dispatch_error
      end
    end
  end

  test "records HTTP failures without following redirects or storing response secrets" do
    [ 503, 302 ].each do |code|
      response = http_response(code, "private response #{@order.customer_phone}")
      response["Location"] = "https://secret.example/redirect?token=private"
      assert_failed_dispatch(->(_http, _request) { response }, "Store returned HTTP #{code}")
    end
  end

  test "rejects empty and malformed JSON confirmations" do
    [ [ nil, "Empty store confirmation" ], [ "", "Empty store confirmation" ],
      [ "private invalid JSON", "Invalid JSON store confirmation" ] ].each do |body, message|
      assert_failed_dispatch(->(_http, _request) { http_response(200, body) }, message)
    end
  end

  test "rejects incompatible JSON roots and data containers" do
    [ nil, false, 1, "private", [], {}, { data: nil }, { data: false },
      { data: [] }, { data: "private" }, { data: 1 } ].each do |body|
      assert_failed_dispatch(->(_http, _request) { http_response(200, body.to_json) }, "Invalid store confirmation")
    end
  end

  test "requires literal accepted true and exact integer order and restaurant identifiers" do
    invalid_data = [ confirmation[:data].except(:accepted) ]
    [ false, nil, "true", 1 ].each { |value| invalid_data << confirmation[:data].merge(accepted: value) }
    { order_id: @order.id, restaurant_id: @order.restaurant_id }.each do |field, id|
      invalid_data << confirmation[:data].except(field)
      [ nil, id.to_s, id.to_f, id + 1, id + 0.5 ].each do |value|
        invalid_data << confirmation[:data].merge(field => value)
      end
    end

    invalid_data.each do |data|
      assert_failed_dispatch(->(_http, _request) { http_response(200, { data: data }.to_json) }, "Invalid store confirmation")
    end
  end

  test "records every expected transport exception without leaking exception details" do
    exceptions = [
      Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError,
      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE,
      Errno::ETIMEDOUT, Errno::EHOSTUNREACH, Errno::ENETUNREACH, EOFError, IOError,
      OpenSSL::SSL::SSLError, Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
    ]
    exceptions.each do |exception_class|
      handler = lambda do |_http, _request|
        raise exception_class, "https://secret.example/?token=private #{@order.customer_name} #{@order.customer_phone}"
      end
      assert_failed_dispatch(handler, "Dispatch transport failed (#{exception_class.name})")
    end
  end

  test "propagates unexpected programming errors without changing persisted state" do
    before = @order.attributes
    handler = ->(_http, _request) { raise NoMethodError, "Unexpected programming failure" }

    with_http_transport(handler) do
      assert_raises(NoMethodError) { Orders::Dispatch.new(@order).call }
    end

    assert_equal before, @order.reload.attributes
  end

  test "propagates database update failures rather than classifying them as transport failures" do
    original = @order.method(:update!)
    before = @order.attributes
    @order.define_singleton_method(:update!) { |**_attributes| raise ActiveRecord::StatementInvalid, "Database failure" }
    handler = ->(_http, _request) { http_response(200, confirmation.to_json) }

    with_http_transport(handler) do
      error = assert_raises(ActiveRecord::StatementInvalid) { Orders::Dispatch.new(@order).call }
      assert_equal "Database failure", error.message
    end
    assert_equal before, @order.reload.attributes
  ensure
    @order.define_singleton_method(:update!, original) if original
  end

  test "rejects an unsaved order without sending HTTP" do
    with_http_transport(->(_http, _request) { flunk "Unexpected HTTP request" }) do
      assert_raises(ArgumentError) { Orders::Dispatch.new(Order.new).call }
    end
  end

  test "reloads an already sent order and skips HTTP even when the instance is dirty pending" do
    @order.update!(dispatch_status: :sent, dispatched_at: Time.current)
    before = @order.attributes
    @order.dispatch_status = :pending

    with_http_transport(->(_http, _request) { flunk "Unexpected HTTP request" }) do
      assert_same @order, Orders::Dispatch.new(@order).call
    end

    assert_equal before, @order.reload.attributes
  end

  test "rejects dispatch inside an explicit database transaction without sending HTTP" do
    before = @order.attributes
    with_http_transport(->(_http, _request) { flunk "Unexpected HTTP request" }) do
      Order.transaction do
        assert_raises(ArgumentError) { Orders::Dispatch.new(@order).call }
      end
    end

    assert_equal before, @order.reload.attributes
  end

  private
    def confirmation
      { data: { accepted: true, order_id: @order.id, restaurant_id: @order.restaurant_id } }
    end

    def expected_payload
      {
        "order_id" => @order.id, "restaurant_id" => @order.restaurant_id, "order_type" => "delivery",
        "customer" => { "name" => "Test Customer", "phone" => "+56000000000" },
        "delivery_address" => "Test Street 123", "total_amount" => 2460,
        "items" => [ { "product_id" => products(:one).id, "quantity" => 2, "unit_price" => 1230 } ]
      }
    end

    def dispatch_with(handler)
      persisted = Order.find(@order.id)
      unchanged = persisted.attributes.except("dispatch_status", "dispatched_at", "last_dispatch_error", "updated_at")
      items = persisted.order_items.order(:id).map(&:attributes)
      calls = 0
      transport = lambda do |http, request|
        calls += 1
        assert_not Order.connection.transaction_open?
        handler.call(http, request)
      end
      assert_no_difference [ -> { Order.count }, -> { OrderItem.count } ] do
        with_http_transport(transport) { assert_same @order, Orders::Dispatch.new(@order).call }
      end
      assert_equal 1, calls
      assert_equal unchanged, @order.reload.attributes.slice(*unchanged.keys)
      assert_equal items, @order.order_items.order(:id).map(&:attributes)
    end

    def assert_failed_dispatch(handler, message)
      @order.update!(dispatched_at: 1.day.ago, last_dispatch_error: "Previous failure")
      dispatch_with(handler)

      assert @order.reload.error?
      assert_nil @order.dispatched_at
      assert_equal message, @order.last_dispatch_error
      assert_operator @order.last_dispatch_error.length, :<, 160
      [ "private", "secret.example", @order.customer_name, @order.customer_phone, @order.delivery_address ].each do |secret|
        assert_not_includes @order.last_dispatch_error, secret
      end
    end
end
