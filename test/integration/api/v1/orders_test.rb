require "test_helper"
require_relative "../../../support/http_transport_helper"

class Api::V1::OrdersTest < ActionDispatch::IntegrationTest
  include HttpTransportHelper

  # Dispatch must follow a real commit, not a savepoint inside the test transaction.
  self.use_transactional_tests = false

  setup do
    @created_order_ids = []
    @http_requests = []
    @transport = ->(http, request) do
      @http_requests << [ http, request ]
      body = JSON.parse(request.body)
      http_response(200, JSON.generate(data: {
        accepted: true, order_id: body.fetch("order_id"),
        restaurant_id: body.fetch("restaurant_id"), duplicate: false
      }))
    end
    @payload = {
      restaurant_id: restaurants(:one).id, order_type: "pickup",
      customer: { name: "Test Customer", phone: "+56000000000" },
      items: [ { product_id: products(:one).id, quantity: 1 } ]
    }
  end

  teardown do
    OrderItem.where(order_id: @created_order_ids).delete_all
    Order.where(id: @created_order_ids).delete_all
  end

  test "creates a pickup with catalog totals and explicit persisted relationships" do
    products(:two).update!(price: 1250)
    @payload[:items] = [
      { product_id: products(:one).id, quantity: 2 },
      { product_id: products(:two).id, quantity: 3 }
    ]
    catalog = Product.order(:id).map(&:attributes)
    order = post_order

    assert_equal 13_730, response.parsed_body.dig("data", "total_amount")
    assert_equal 13_730, order.total_amount
    assert_equal restaurants(:one), order.restaurant
    assert_equal "pickup", order.order_type
    assert_equal "Test Customer", order.customer_name
    assert_equal "+56000000000", order.customer_phone
    assert_nil order.delivery_address
    assert_nil order.client_total_amount
    [ [ products(:one), 2, 4990 ], [ products(:two), 3, 1250 ] ].each do |product, quantity, price|
      item = order.order_items.find_by!(product_id: product.id)
      assert_equal [ order.id, product.id, quantity, price ],
        [ item.order_id, item.product_id, item.quantity, item.unit_price ]
    end
    assert_equal catalog, Product.order(:id).map(&:attributes)
  end

  test "creates a delivery with its address" do
    order = post_order(@payload.merge(order_type: "delivery", delivery_address: "Test Street 123"))

    assert_equal "delivery", response.parsed_body.dig("data", "order_type")
    assert_equal "delivery", order.order_type
    assert_equal "Test Street 123", order.delivery_address
    assert_equal 4990, order.total_amount
  end

  test "accepts omitted null and matching client totals" do
    [ {}, { client_total_amount: nil }, { client_total_amount: 4990 } ].each do |attributes|
      order = post_order(@payload.merge(attributes))

      assert_equal 4990, order.total_amount
      if attributes[:client_total_amount].nil?
        assert_nil order.client_total_amount
        assert_nil response.parsed_body.dig("data", "client_total_amount")
      else
        assert_equal 4990, order.client_total_amount
        assert_equal 4990, response.parsed_body.dig("data", "client_total_amount")
      end
    end
  end

  test "rejects differing totals including zero with both CLP amounts" do
    [ 123, 0 ].each do |amount|
      errors = reject_order(@payload.merge(client_total_amount: amount), "client_total_amount", code: "total_mismatch")
      message = errors.find { |error| error["code"] == "total_mismatch" }.fetch("message")

      assert_match(/\b#{amount}\b/, message)
      assert_match(/\b4990\b/, message)
      assert_match(/CLP/i, message)
      assert_match(/declared|provided|client/i, message)
      assert_match(/calculated|computed|expected/i, message)
    end
  end

  test "accepts a zero total for free catalog items" do
    @payload.merge!(items: [ { product_id: products(:two).id, quantity: 3 } ], client_total_amount: 0)
    order = post_order

    assert_equal 0, order.total_amount
    assert_equal 0, order.client_total_amount
    assert_equal 0, order.order_items.sole.unit_price
    assert_equal 0, response.parsed_body.dig("data", "total_amount")
  end

  test "rejects invalid client totals rather than comparing them" do
    [ -1, 1.0, 1.5, "1.0", "1.5", "", "invalid" ].each do |amount|
      reject_order(@payload.merge(client_total_amount: amount), "client_total_amount")
    end
  end

  test "requires restaurant order type and customer name and phone" do
    %i[restaurant_id order_type].each do |field|
      reject_order(@payload.except(field), field.to_s)
      reject_order(@payload.merge(field => nil), field.to_s)
    end
    [ @payload.except(:customer), @payload.merge(customer: nil), @payload.merge(customer: {}) ].each do |payload|
      errors = reject_order(payload, "customer.name")
      assert_includes errors.pluck("field"), "customer.phone"
    end
    %i[name phone].each do |field|
      [ nil, "", "   " ].each do |value|
        payload = @payload.deep_dup
        payload[:customer][field] = value
        reject_order(payload, "customer.#{field}")
      end
      payload = @payload.deep_dup
      payload[:customer].delete(field)
      reject_order(payload, "customer.#{field}")
    end
  end

  test "requires a nonblank delivery address" do
    [ {}, { delivery_address: nil }, { delivery_address: "" }, { delivery_address: "   " } ].each do |attributes|
      reject_order(@payload.merge(order_type: "delivery").merge(attributes), "delivery_address")
    end
  end

  test "requires items and rejects duplicate products" do
    [ @payload.except(:items), @payload.merge(items: nil), @payload.merge(items: []) ].each do |payload|
      reject_order(payload, "items")
    end
    reject_order(@payload.merge(items: [ @payload[:items].first, @payload[:items].first ]), "items")
  end

  test "rejects invalid quantities with their original item index" do
    [ nil, 0, -1, 1.0, 1.5, "1.0", "1.5", "invalid" ].each do |quantity|
      payload = @payload.merge(items: [ @payload[:items].first,
        { product_id: products(:two).id, quantity: quantity } ], client_total_amount: 4990)
      reject_order(payload, "items[1].quantity")
    end
  end

  test "rejects nonexistent restaurant and product references without partial records" do
    reject_order(@payload.merge(restaurant_id: -1), "restaurant_id")
    reject_order(@payload.merge(items: [ @payload[:items].first, { product_id: -1, quantity: 1 } ],
      client_total_amount: 4990), "items[1].product_id")
  end

  test "client supplied internal attributes cannot influence persisted values" do
    @payload.merge!(total_amount: 1, dispatch_status: "sent", last_dispatch_error: "Injected error",
      dispatched_at: "2026-01-01T00:00:00Z", customer_name: "Injected name", customer_phone: "Injected phone")
    @payload[:items].first.merge!(unit_price: 1, order_id: -1)
    order = post_order

    assert_equal 4990, order.total_amount
    assert_equal 4990, order.order_items.sole.unit_price
    assert_equal "Test Customer", order.customer_name
    assert_equal "+56000000000", order.customer_phone
    assert_nil order.last_dispatch_error
    assert_predicate order.dispatched_at, :present?
    assert_not_equal Time.iso8601(@payload[:dispatched_at]), order.dispatched_at
  end

  test "dispatches only after the order and items are committed and visible to another connection" do
    @payload[:items] << { product_id: products(:two).id, quantity: 2 }
    transport = @transport
    @transport = ->(http, request) do
      assert_not Order.connection.transaction_open?
      body = JSON.parse(request.body)
      pool = Order.connection_pool
      connection = pool.checkout
      begin
        assert_not_same Order.connection, connection
        order_id = connection.quote(Integer(body.fetch("order_id")))
        rows = connection.select_all("SELECT * FROM orders WHERE id = #{order_id}").to_a
        assert_equal 1, rows.size
        row = rows.sole
        assert_equal body.fetch("restaurant_id"), row.fetch("restaurant_id")
        assert_equal Order.order_types.fetch(body.fetch("order_type")), row.fetch("order_type")
        assert_equal body.fetch("customer").fetch("name"), row.fetch("customer_name")
        assert_equal body.fetch("customer").fetch("phone"), row.fetch("customer_phone")
        assert_nil row.fetch("delivery_address")
        assert_equal body.fetch("total_amount"), row.fetch("total_amount")
        assert_equal Order.dispatch_statuses.fetch("pending"), row.fetch("dispatch_status")
        items = connection.select_all(
          "SELECT product_id, quantity, unit_price FROM order_items WHERE order_id = #{order_id} ORDER BY id"
        ).to_a
        assert_equal 2, items.size
        assert_equal body.fetch("items"), items
      ensure
        pool.checkin(connection)
      end
      transport.call(http, request)
    end

    post_order

    assert_equal 1, @http_requests.size
  end

  test "keeps the created order and items and returns the same data fields when dispatch receives HTTP 503" do
    @transport = ->(http, request) do
      @http_requests << [ http, request ]
      http_response(503, JSON.generate(errors: [ { message: "Private store failure details" } ]))
    end

    order = post_order(dispatch_status: "error")

    assert_equal 1, @http_requests.size
    assert_equal "error", response.parsed_body.dig("data", "dispatch_status")
    assert_nil order.dispatched_at
    assert_equal "Store returned HTTP 503", order.last_dispatch_error
    assert_equal restaurants(:one).id, order.restaurant_id
    assert_equal 4990, order.total_amount
    item = order.order_items.sole
    assert_equal [ order.id, products(:one).id, 1, 4990 ],
      [ item.order_id, item.product_id, item.quantity, item.unit_price ]
  end

  test "rejects non object customers and non array item collections" do
    [ "invalid", [], 123, false ].each do |customer|
      reject_order(@payload.merge(customer: customer), "customer", code: "invalid_structure")
    end
    [ {}, "invalid", 123, false ].each do |items|
      reject_order(@payload.merge(items: items), "items", code: "invalid_structure")
    end
  end

  test "rejects non object items after a valid item without discarding null" do
    [ nil, 123, "invalid", [], false ].each do |item|
      reject_order(@payload.merge(items: [ @payload[:items].first, item ]), "items[1]", code: "invalid_structure")
    end
  end

  test "preserves indexes for null before valid items and multiple nulls" do
    [ [ nil, @payload[:items].first ], [ nil, @payload[:items].first, nil, nil ] ].each do |items|
      errors = reject_order(@payload.merge(items: items), "items[0]", code: "invalid_structure")

      expected = items.each_index.select { |index| items[index].nil? }.map { |index| "items[#{index}]" }
      assert_equal expected, errors.pluck("field")
      assert errors.all? { |error| error["code"] == "invalid_structure" }
    end
  end

  test "rejects valid JSON roots that are not objects" do
    [ [], [ @payload ], "invalid", 123, true, false, nil ].each do |payload|
      reject_order(payload, "base", code: "invalid_structure")
    end
  end

  test "accepts an unknown underscore json key in a valid root object" do
    order = post_order(@payload.merge("_json" => "value"))

    assert_equal restaurants(:one).id, order.restaurant_id
    assert_equal 4990, order.total_amount
  end

  test "does not unwrap an order wrapper to supply missing root fields" do
    errors = reject_order({ order: @payload }, "restaurant_id")

    %w[order_type customer.name customer.phone items].each do |field|
      assert_includes errors.pluck("field"), field
    end
  end

  test "rejects numeric and structured order types instead of accepting enum integers" do
    [ 0, 1, [], {}, true ].each do |order_type|
      reject_order(@payload.merge(order_type: order_type), "order_type", code: "invalid_structure")
    end
    reject_order(@payload.merge(order_type: "invalid"), "order_type")
  end

  test "rejects arrays and objects in scalar fields instead of silently filtering them" do
    fields = {
      "restaurant_id" => [ :restaurant_id ], "delivery_address" => [ :delivery_address ],
      "client_total_amount" => [ :client_total_amount ], "customer.name" => [ :customer, :name ],
      "customer.phone" => [ :customer, :phone ], "items[0].product_id" => [ :items, 0, :product_id ],
      "items[0].quantity" => [ :items, 0, :quantity ]
    }
    fields.each do |field, path|
      [ [], {} ].each do |value|
        payload = @payload.deep_dup
        parent = path.size == 1 ? payload : payload.dig(*path[0...-1])
        parent[path.last] = value
        reject_order(payload, field, code: "invalid_structure")
      end
    end
  end

  test "returns a fixed safe error for malformed JSON" do
    [ "", " \n", '{"customer":"private input",', '{"items":[}' ].each do |body|
      errors = reject_order(body, "base", code: "invalid_json", status: :bad_request, raw: true)

      assert_equal [ { "field" => "base", "code" => "invalid_json", "message" => "Malformed JSON body" } ], errors
    end
  end

  private
    def post_json(payload, raw: false)
      previous_ids = Order.ids
      with_http_transport(@transport) do
        post "/api/v1/orders", params: raw ? payload.dup : ActiveSupport::JSON.encode(payload),
          headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
      end
    ensure
      @created_order_ids.concat(Order.where.not(id: previous_ids).ids) if previous_ids
    end

    def post_order(payload = @payload, dispatch_status: "sent")
      assert_difference -> { Order.count }, 1 do
        assert_difference -> { OrderItem.count }, payload.fetch(:items).size do
          post_json(payload)
        end
      end
      assert_response :created
      assert_equal "application/json", response.media_type
      assert_equal [ "data" ], response.parsed_body.keys
      data = response.parsed_body.fetch("data")
      assert_equal %w[client_total_amount created_at dispatch_status id order_type restaurant_id total_amount], data.keys.sort
      order = Order.find(data.fetch("id"))
      assert_equal order.as_json(only: data.keys), data
      assert_equal dispatch_status, data.fetch("dispatch_status")
      assert_kind_of String, data.fetch("created_at")
      if dispatch_status == "sent"
        assert_predicate order, :sent?
        assert_predicate order.dispatched_at, :present?
        assert_nil order.last_dispatch_error
      else
        assert_predicate order, :error?
      end
      order
    end

    def reject_order(payload, field, code: nil, status: :unprocessable_content, raw: false)
      assert_no_difference [ -> { Order.count }, -> { OrderItem.count }, -> { @http_requests.size } ] do
        post_json(payload, raw: raw)
      end
      assert_response status
      assert_equal "application/json", response.media_type
      assert_equal [ "errors" ], response.parsed_body.keys
      errors = response.parsed_body.fetch("errors")
      assert_kind_of Array, errors
      assert_not_empty errors
      errors.each do |error|
        assert_kind_of Hash, error
        assert_equal %w[code field message], error.keys.sort
        error.each_value do |value|
          assert_kind_of String, value
          assert_not_empty value
        end
      end
      assert errors.any? { |error| error["field"] == field && (code.nil? || error["code"] == code) }, errors.inspect
      assert_equal code == "total_mismatch", errors.any? { |error| error["code"] == "total_mismatch" }
      errors
    end
end
