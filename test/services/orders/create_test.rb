require "test_helper"

class Orders::CreateTest < ActiveSupport::TestCase
  setup do
    @attributes = {
      restaurant_id: restaurants(:one).id, order_type: "pickup",
      customer: { name: "Test Customer", phone: "+56000000000" },
      items: [ { product_id: products(:one).id, quantity: 1 } ]
    }
  end

  test "calculates multiple items from catalog prices and persists pending relationships" do
    products(:two).update!(price: 1250)
    @attributes[:items] = [
      { product_id: products(:one).id, quantity: 2 },
      { product_id: products(:two).id, quantity: 3 }
    ]
    catalog = Product.order(:id).map(&:attributes)

    assert_difference -> { Order.count }, 1 do
      assert_difference -> { OrderItem.count }, 2 do
        @result = create_order
      end
    end
    order = @result.order.reload
    assert_empty @result.errors
    assert_equal 13_730, order.total_amount
    assert order.pending?
    assert_equal restaurants(:one), order.restaurant
    assert_equal "Test Customer", order.customer_name
    assert_equal "+56000000000", order.customer_phone
    assert_equal "pickup", order.order_type
    assert_nil order.delivery_address
    assert_includes restaurants(:one).orders, order
    [ [ products(:one), 2, 4990 ], [ products(:two), 3, 1250 ] ].each do |product, quantity, price|
      item = order.order_items.find_by!(product: product)
      assert_equal [ quantity, price ], [ item.quantity, item.unit_price ]
      assert_equal order, item.order
      assert_includes product.order_items, item
    end
    assert_equal catalog, Product.order(:id).map(&:attributes)
  end

  test "preserves historical totals and prices after catalog changes" do
    order = create_order.order
    assert order.persisted?
    products(:one).update!(price: 7500)

    assert_equal 4990, order.reload.total_amount
    assert_equal 4990, order.order_items.sole.reload.unit_price
    assert_equal 7500, create_order.order.reload.total_amount
  end

  test "accepts omitted nil matching and integer string client totals" do
    [ {}, { client_total_amount: nil }, { client_total_amount: 4990 },
      { client_total_amount: "4990" } ].each do |attributes|
      result = create_order(@attributes.merge(attributes))

      assert result.order.persisted?, result.errors.inspect
      assert_empty result.errors
      assert_equal 4990, result.order.reload.total_amount
      if attributes[:client_total_amount].nil?
        assert_nil result.order.client_total_amount
      else
        assert_equal 4990, result.order.client_total_amount
      end
    end
  end

  test "rejects differing totals with both declared and calculated CLP amounts" do
    [ 123, 0 ].each do |amount|
      result = reject_order(@attributes.merge(client_total_amount: amount), "client_total_amount", mismatch: true)
      error = result.errors.find { |entry| entry[:code] == "total_mismatch" }

      assert_equal "client_total_amount", error[:field]
      assert_match(/\b#{amount}\b/, error[:message])
      assert_match(/\b4990\b/, error[:message])
      assert_match(/CLP/i, error[:message])
      assert_match(/declared|provided|client/i, error[:message])
      assert_match(/calculated|computed|expected/i, error[:message])
    end
  end

  test "accepts a zero client total for free catalog items" do
    @attributes[:items] = [ { product_id: products(:two).id, quantity: 3 } ]
    @attributes[:client_total_amount] = 0
    result = create_order

    assert result.order.persisted?, result.errors.inspect
    assert_empty result.errors
    assert_equal 0, result.order.reload.total_amount
    assert_equal 0, result.order.client_total_amount
    assert_equal 0, result.order.order_items.sole.unit_price
  end

  test "rejects invalid client totals without comparing them" do
    [ -1, 1.0, 1.5, "1.0", "1.5", "", "   ", "invalid" ].each do |amount|
      reject_order(@attributes.merge(client_total_amount: amount), "client_total_amount")
    end
  end

  test "rejects a missing or nonexistent restaurant before comparing totals" do
    [ nil, -1 ].each do |id|
      reject_order(@attributes.merge(restaurant_id: id, client_total_amount: 0), "restaurant_id")
    end
  end

  test "indexes missing product errors and never compares a valid partial total" do
    @attributes[:items] = [
      { product_id: -1, quantity: 2 },
      { product_id: products(:one).id, quantity: 3 }
    ]
    @attributes[:client_total_amount] = 14_970
    result = reject_order(@attributes, "items[0].product_id")

    assert_equal 2, result.order.order_items.size
    assert result.order.order_items.none?(&:persisted?)
  end

  test "requires customer name and phone including omitted and nil customer" do
    [ @attributes.except(:customer), @attributes.merge(customer: nil),
      @attributes.merge(customer: {}) ].each do |attributes|
      result = reject_order(attributes, "customer.name")
      assert_includes result.errors.pluck(:field), "customer.phone"
    end
    %i[name phone].each do |field|
      [ nil, "", "   " ].each do |value|
        attributes = @attributes.deep_dup
        attributes[:customer][field] = value
        reject_order(attributes, "customer.#{field}")
      end
    end
  end

  test "requires order type and a delivery address through model validations" do
    reject_order(@attributes.except(:order_type), "order_type")
    reject_order(@attributes.merge(order_type: "delivery"), "delivery_address")
    result = create_order(@attributes.merge(order_type: "delivery", delivery_address: "Test Street 123"))

    assert result.order.persisted?, result.errors.inspect
    assert_equal "delivery", result.order.reload.order_type
    assert_equal "Test Street 123", result.order.delivery_address
  end

  test "requires items including omitted nil and empty arrays" do
    [ @attributes.except(:items), @attributes.merge(items: nil), @attributes.merge(items: []) ].each do |attributes|
      reject_order(attributes, "items")
    end
  end

  test "rejects duplicate products without persisting or comparing totals" do
    @attributes[:items] << @attributes[:items].first.dup
    @attributes[:client_total_amount] = 4990

    reject_order(@attributes, "items")
  end

  test "indexes invalid quantities without comparing a valid partial total" do
    [ nil, 0, -1, 1.0, 1.5, "1.0", "1.5", "invalid" ].each do |quantity|
      attributes = @attributes.merge(
        items: [ { product_id: products(:two).id, quantity: quantity },
          { product_id: products(:one).id, quantity: 2 } ], client_total_amount: 9980
      )
      reject_order(attributes, "items[0].quantity")
    end
  end

  test "ignores client supplied internal order and item attributes" do
    @attributes.merge!(total_amount: 1, dispatch_status: "sent", last_dispatch_error: "Injected error",
      dispatched_at: "2026-01-01T00:00:00Z", customer_name: "Injected name", customer_phone: "Injected phone")
    @attributes[:items].first.merge!(unit_price: 1, order_id: -1)
    result = create_order

    assert result.order.persisted?, result.errors.inspect
    order = result.order.reload
    assert_equal 4990, order.total_amount
    assert_equal 4990, order.order_items.sole.unit_price
    assert_equal "Test Customer", order.customer_name
    assert_equal "+56000000000", order.customer_phone
    assert order.pending?
    assert_nil order.last_dispatch_error
    assert_nil order.dispatched_at
  end

  test "accepts string and mixed keys without mutating deeply frozen input" do
    [ @attributes, @attributes.deep_stringify_keys,
      @attributes.merge(customer: @attributes[:customer].stringify_keys,
        items: [ { "product_id" => products(:one).id, quantity: 1 } ]) ].each do |attributes|
      original = attributes.deep_dup
      freeze_input(attributes)
      result = create_order(attributes)

      assert result.order.persisted?, result.errors.inspect
      assert_empty result.errors
      assert_equal 4990, result.order.reload.total_amount
      assert_equal original, attributes
    end
  end

  test "propagates a second item database failure and rolls back the order and first item" do
    first_product_id = products(:one).id
    second_product_id = products(:two).id
    @attributes[:items] << { product_id: second_product_id, quantity: 3 }
    observed = nil
    callback = lambda do |item|
      if item.product_id == second_product_id
        observed = [ Order.exists?(item.order_id),
          OrderItem.exists?(order_id: item.order_id, product_id: first_product_id), item.quantity ]
        item.quantity = 0
      end
    end
    OrderItem.set_callback(:create, :before, callback)

    assert_no_difference [ -> { Order.count }, -> { OrderItem.count } ] do
      error = assert_raises(ActiveRecord::StatementInvalid) { create_order }
      assert_kind_of PG::CheckViolation, error.cause
    end
    assert_equal [ true, true, 3 ], observed
  ensure
    OrderItem.skip_callback(:create, :before, callback) if callback
  end

  test "rejects a non Hash root input without persisting" do
    [ nil, [], "invalid", 123, false ].each do |attributes|
      result = reject_order(attributes, "base")

      assert_equal [ { field: "base", code: "invalid_structure", message: "must be a Hash" } ], result.errors
    end
  end

  test "rejects non Hash customers without mutating string or symbol keyed input" do
    [ "invalid", [], 123, false ].each do |customer|
      [ @attributes.merge(customer: customer), @attributes.merge(customer: customer).deep_stringify_keys ].each do |attributes|
        original = attributes.deep_dup
        freeze_input(attributes)
        result = reject_order(attributes, "customer")

        assert_equal [ { field: "customer", code: "invalid_structure", message: "must be a Hash" } ], result.errors
        assert_equal original, attributes
      end
    end
  end

  test "rejects non Array items instead of normalizing them" do
    [ {}, @attributes[:items].first, "invalid", 123, false ].each do |items|
      result = reject_order(@attributes.merge(items: items), "items")

      assert_equal [ { field: "items", code: "invalid_structure", message: "must be an Array" } ], result.errors
    end
  end

  test "indexes every non Hash item without building a partial order" do
    attributes = @attributes.deep_stringify_keys
    attributes["items"].concat([ nil, 123, "invalid" ])
    original = attributes.deep_dup
    freeze_input(attributes)
    result = reject_order(attributes, "items[1]")

    assert_equal [
      { field: "items[1]", code: "invalid_structure", message: "must be a Hash" },
      { field: "items[2]", code: "invalid_structure", message: "must be a Hash" },
      { field: "items[3]", code: "invalid_structure", message: "must be a Hash" }
    ], result.errors
    assert_empty result.order.order_items
    assert_equal original, attributes
  end

  private
    def create_order(attributes = @attributes)
      service = Orders::Create.new(attributes)
      result = service.call
      assert_same service, result
      assert_kind_of Array, result.errors
      result.errors.each do |error|
        assert_equal %i[code field message], error.keys.sort
        error.each_value { |value| assert_kind_of String, value }
        assert error.values.all?(&:present?)
      end
      result
    end

    def reject_order(attributes, field, mismatch: false)
      result = nil
      assert_no_difference [ -> { Order.count }, -> { OrderItem.count } ] do
        result = create_order(attributes)
      end
      assert_not result.order.persisted?, attributes.inspect
      assert result.order.order_items.none?(&:persisted?)
      assert_equal 0, result.order.total_amount unless mismatch
      assert_includes result.errors.pluck(:field), field
      assert_equal mismatch, result.errors.any? { |error| error[:code] == "total_mismatch" }
      result
    end

    def freeze_input(value)
      case value
      when Hash
        value.each { |key, entry| freeze_input(key); freeze_input(entry) }
      when Array
        value.each { |entry| freeze_input(entry) }
      end
      value.freeze
    end
end
