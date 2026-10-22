require "test_helper"
require_relative "../../../support/http_transport_helper"

class Api::V1::OrderQueriesTest < ActionDispatch::IntegrationTest
  include HttpTransportHelper

  test "returns an empty data array when there are no orders" do
    query_get

    assert_equal({ "data" => [] }, response.parsed_body)
  end

  test "lists exact public summaries across restaurants and dispatch statuses" do
    orders = %w[pending sent error].each_with_index.map do |status, index|
      build_order(restaurant: restaurants(index.even? ? :one : :two), dispatch_status: status,
        order_type: :delivery, delivery_address: "Test Street 123", client_total_amount: 2460,
        last_dispatch_error: status == "error" ? "Store returned HTTP 503" : nil)
    end

    query_get

    data = response.parsed_body.fetch("data")
    assert_instance_of Array, data
    assert_equal orders.map(&:id).sort, data.pluck("id").sort
    data.each do |summary|
      order = orders.find { |record| record.id == summary.fetch("id") }
      assert_summary(order, summary)
      %w[customer customer_name customer_phone delivery_address items client_total_amount
        dispatch_url dispatched_at last_dispatch_error updated_at].each do |field|
        assert_not summary.key?(field), "Summary exposes #{field}"
      end
      assert_not summary.fetch("restaurant").key?("dispatch_url")
    end
  end

  test "sorts by descending creation time and descending id for ties" do
    first = build_order
    second = build_order
    recent = build_order
    oldest = build_order
    timestamp = Time.utc(2026, 1, 2, 12, 0, 0, 123456)
    first.update_columns(created_at: timestamp)
    second.update_columns(created_at: timestamp)
    recent.update_columns(created_at: timestamp + 1.hour)
    oldest.update_columns(created_at: timestamp - 1.hour)

    query_get

    assert_equal [ recent.id, second.id, first.id, oldest.id ], response.parsed_body.fetch("data").pluck("id")
  end

  test "returns exact delivery details with items sorted by ascending id" do
    order = build_order(order_type: :delivery, delivery_address: "Test Street 123",
      client_total_amount: 2460, dispatch_status: :sent, dispatched_at: Time.utc(2026, 1, 2, 12, 0, 0, 123456))
    second = order.order_items.create!(product: products(:two), quantity: 3, unit_price: 450)
    first = order.order_items.first
    # Reverse physical insertion order relative to IDs to exercise explicit item sorting.
    first.update_columns(id: second.id + 1)

    query_get(order.id)

    data = assert_detail(order)
    assert_equal [ second.id, first.id ], data.fetch("items").pluck("id")
    assert_equal({ "name" => "Test Customer", "phone" => "+56000000000" }, data.fetch("customer"))
    assert_equal "Test Street 123", data.fetch("delivery_address")
    assert_equal 2460, data.fetch("client_total_amount")
    assert_instance_of Integer, data.fetch("client_total_amount")
    assert_instance_of String, data.fetch("dispatched_at")
    assert_equal order.dispatched_at.iso8601(3), data.fetch("dispatched_at")
    assert_nil data.fetch("last_dispatch_error")
  end

  test "returns explicit null optional fields for a pending pickup" do
    order = build_order

    query_get(order.id)

    data = assert_detail(order)
    %w[client_total_amount delivery_address dispatched_at last_dispatch_error].each do |field|
      assert_nil data.fetch(field)
    end
    assert_equal "pickup", data.fetch("order_type")
  end

  test "preserves zero integer CLP amounts and operational error text" do
    order = build_order(total_amount: 0, client_total_amount: 0, dispatch_status: :error,
      last_dispatch_error: "Store returned HTTP 503")
    order.order_items.sole.update!(unit_price: 0)

    query_get(order.id)

    data = assert_detail(order)
    %w[total_amount client_total_amount].each do |field|
      assert_equal 0, data.fetch(field)
      assert_instance_of Integer, data.fetch(field)
    end
    assert_equal 0, data.fetch("items").sole.fetch("unit_price")
    assert_equal 0, data.fetch("items").sole.fetch("subtotal")
    assert_equal "Store returned HTTP 503", data.fetch("last_dispatch_error")
    assert_nil data.fetch("dispatched_at")
  end

  test "reads current catalog labels but historical prices subtotals and persisted total" do
    # Deliberately different from the item sum: GET must not recompute stored totals.
    order = build_order(total_amount: 7777)
    products(:one).update!(name: "Renamed Test Product", sku: "RENAMED-TEST-SKU", price: 9999)

    query_get(order.id)

    data = assert_detail(order)
    item = data.fetch("items").sole
    assert_equal "Renamed Test Product", item.fetch("product_name")
    assert_equal "RENAMED-TEST-SKU", item.fetch("sku")
    assert_equal 1230, item.fetch("unit_price")
    assert_equal 2460, item.fetch("subtotal")
    assert_equal 7777, data.fetch("total_amount")
  end

  test "returns the same exact not found error contract as retry dispatch" do
    query_get(-1, status: :not_found)

    assert_equal({ "errors" => [ {
      "field" => "id", "code" => "not_found", "message" => "Order not found"
    } ] }, response.parsed_body)
  end

  test "list detail and missing detail perform no writes or outbound HTTP" do
    order = build_order(dispatch_status: :error, last_dispatch_error: "Store returned HTTP 503")
    before = persisted_snapshot
    query_get # Warm routing and lazy framework initialization before SQL capture.

    statements = capture_sql do
      query_get
      query_get(order.id)
      query_get(-1, status: :not_found)
    end

    assert_equal before, persisted_snapshot
    writes = statements.select do |sql|
      sql.match?(/\b(?:INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|TRUNCATE|REINDEX|COMMENT|GRANT|REVOKE)\b/i)
    end
    assert_empty writes, "GET issued write SQL: #{writes.inspect}"
  end

  test "list uses two selects independent of order count without loading items or products" do
    build_order
    query_get
    small = capture_sql { query_get }
    4.times do |index|
      build_order(restaurant: restaurants(index.even? ? :two : :one))
    end
    large = capture_sql { query_get }

    assert_equal 5, response.parsed_body.fetch("data").size
    [ small, large ].each do |statements|
      selects = statements.grep(/\A\s*SELECT\b/i)
      assert_equal 2, selects.size, selects.inspect
      assert selects.any? { |sql| sql.match?(/\bFROM\s+"?orders"?\b/i) }, selects.inspect
      assert selects.any? { |sql| sql.match?(/\bFROM\s+"?restaurants"?\b/i) }, selects.inspect
      assert_empty statements.grep(/\b(?:order_items|products)\b/i)
    end
  end

  test "detail uses at most four selects independent of distinct product count" do
    order = build_order
    query_get(order.id)
    small = capture_sql { query_get(order.id) }
    4.times do |index|
      product = Product.create!(name: "Query Test Product #{index}", sku: "QUERY-TEST-#{index}", price: 9000)
      order.order_items.create!(product: product, quantity: index + 1, unit_price: 100)
    end
    large = capture_sql { query_get(order.id) }

    assert_equal 5, response.parsed_body.fetch("data").fetch("items").size
    counts = [ small, large ].map { |statements| statements.grep(/\A\s*SELECT\b/i).size }
    assert_operator counts.first, :>, 0
    assert_operator counts.last, :<=, 4
    assert_equal counts.first, counts.last
  end

  private
    def build_order(**attributes)
      order = Order.new({ restaurant: restaurants(:one), order_type: :pickup,
        customer_name: "Test Customer", customer_phone: "+56000000000", total_amount: 2460 }.merge(attributes))
      order.order_items.build(product: products(:one), quantity: 2, unit_price: 1230)
      order.save!
      order
    end

    def query_get(id = nil, status: :ok)
      with_http_transport(->(_http, _request) { flunk "GET must not send outbound HTTP" }) do
        get id.nil? ? "/api/v1/orders" : "/api/v1/orders/#{id}", headers: { "ACCEPT" => "application/json" }
      end
      assert_response status
      assert_equal "application/json", response.media_type
      assert_equal [ status == :ok ? "data" : "errors" ], response.parsed_body.keys
    end

    def assert_summary(order, data)
      restaurant = order.restaurant
      assert_equal({
        "id" => order.id, "restaurant_id" => restaurant.id,
        "restaurant" => { "id" => restaurant.id, "name" => restaurant.name, "code" => restaurant.code },
        "total_amount" => order.total_amount, "order_type" => order.order_type,
        "created_at" => order.created_at.iso8601(3), "dispatch_status" => order.dispatch_status
      }, data)
      %w[id restaurant_id total_amount].each { |field| assert_instance_of Integer, data.fetch(field) }
      assert_instance_of Integer, data.fetch("restaurant").fetch("id")
      %w[order_type created_at dispatch_status].each { |field| assert_instance_of String, data.fetch(field) }
      %w[name code].each { |field| assert_instance_of String, data.fetch("restaurant").fetch(field) }
    end

    def assert_detail(order)
      data = response.parsed_body.fetch("data")
      extra_fields = %w[client_total_amount customer delivery_address dispatched_at last_dispatch_error items]
      assert_summary(order, data.except(*extra_fields))
      assert_equal (extra_fields + %w[id restaurant_id restaurant total_amount order_type created_at dispatch_status]).sort,
        data.keys.sort
      assert_equal({ "name" => order.customer_name, "phone" => order.customer_phone }, data.fetch("customer"))
      expected_items = order.order_items.reload.sort_by(&:id).map do |item|
        { "id" => item.id, "product_id" => item.product_id, "product_name" => item.product.name,
          "sku" => item.product.sku, "quantity" => item.quantity, "unit_price" => item.unit_price,
          "subtotal" => item.quantity * item.unit_price }
      end
      assert_equal expected_items, data.fetch("items")
      data.fetch("items").each do |item|
        %w[id product_id quantity unit_price subtotal].each { |field| assert_instance_of Integer, item.fetch(field) }
        %w[product_name sku].each { |field| assert_instance_of String, item.fetch(field) }
      end
      data
    end

    def persisted_snapshot
      [ Order, OrderItem, Product, Restaurant ].map { |model| model.order(:id).map(&:attributes) }
    end

    def capture_sql
      statements = []
      subscriber = ->(_name, _start, _finish, _id, payload) do
        next if %w[SCHEMA TRANSACTION].include?(payload[:name])

        statements << payload.fetch(:sql)
      end
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      end
      statements
    end
end
