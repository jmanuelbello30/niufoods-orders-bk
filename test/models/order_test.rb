require "test_helper"

class OrderTest < ActiveSupport::TestCase
  setup do
    @order = Order.new(
      restaurant: restaurants(:one), order_type: :pickup,
      customer_name: "Test Customer", customer_phone: "+56000000000", total_amount: 1000
    )
    @order.order_items.build(product: products(:one), quantity: 2, unit_price: 500)
  end

  test "persists an order and its items built in memory with inverse relationships" do
    item = @order.order_items.first
    assert_same @order, item.order
    assert item.valid?

    assert_difference -> { Order.count }, 1 do
      assert_difference -> { OrderItem.count }, 1 do
        assert @order.save
      end
    end

    assert_equal @order.id, item.reload.order_id
    assert_equal products(:one), item.product
    assert_equal restaurants(:one), @order.reload.restaurant
    assert_includes restaurants(:one).orders, @order
    assert_includes products(:one).order_items, item
  end

  test "keeps explicitly assigned totals and unit prices without catalog callbacks" do
    @order.total_amount = 123
    @order.order_items.first.unit_price = 77

    assert @order.save
    assert_equal 123, @order.reload.total_amount
    assert_equal 77, @order.order_items.first.unit_price
  end

  test "requires an existing restaurant" do
    [ nil, -1 ].each do |id|
      @order.restaurant_id = id

      assert_not @order.valid?
      assert @order.errors[:restaurant].present?
    end
  end

  test "requires customer name and phone" do
    %i[customer_name customer_phone].each do |attribute|
      [ nil, "", "   " ].each do |value|
        @order[attribute] = value

        assert_not @order.valid?
        assert @order.errors.added?(attribute, :blank)
      end
      @order[attribute] = "Test Value"
    end
  end

  test "has no default order type or total amount and starts pending" do
    order = Order.new

    assert_nil order.order_type
    assert_nil order.total_amount
    assert_nil order.client_total_amount
    assert order.pending?
    assert @order.save
    assert @order.reload.pending?
  end

  test "accepts all declared order types and dispatch statuses" do
    [ :pickup, "pickup", 0, :delivery, "delivery", 1 ].each do |value|
      @order.order_type = value
      @order.delivery_address = "Test Street 123"

      assert @order.valid?, "Expected order type #{value.inspect} to be valid"
    end

    [ :pending, "pending", 0, :sent, "sent", 1, :error, "error", 2 ].each do |value|
      @order.dispatch_status = value

      assert @order.valid?, "Expected status #{value.inspect} to be valid"
    end
  end

  test "invalid enum assignments produce validation errors instead of exceptions" do
    %i[order_type dispatch_status].each do |attribute|
      [ nil, "", "unknown", 99, -1, 1.5 ].each do |value|
        @order.public_send("#{attribute}=", value)

        assert_not @order.valid?
        assert @order.errors[attribute].present?, "Expected an error for #{attribute}=#{value.inspect}"
      end
      @order.public_send("#{attribute}=", 0)
    end
  end

  test "requires a delivery address for delivery orders" do
    @order.order_type = :delivery

    [ nil, "", "   " ].each do |value|
      @order.delivery_address = value

      assert_not @order.valid?
      assert @order.errors.added?(:delivery_address, :blank)
    end

    @order.delivery_address = "Test Street 123"
    assert @order.save
    assert_equal "Test Street 123", @order.reload.delivery_address
  end

  test "allows a missing delivery address for pickup" do
    @order.delivery_address = nil

    assert @order.save
    assert_nil @order.reload.delivery_address
  end

  test "requires at least one item" do
    @order.order_items.clear

    assert_not @order.valid?
    assert @order.errors.added?(:order_items, :blank)
    assert_not @order.save
  end

  test "rejects invalid new items without persisting a partial order" do
    @order.order_items.build(product: products(:two), quantity: 0, unit_price: 100)

    assert_no_difference [ -> { Order.count }, -> { OrderItem.count } ] do
      assert_not @order.save
    end
    assert @order.errors[:order_items].present?
    assert @order.order_items.last.errors[:quantity].present?
  end

  test "rejects changes to invalid persisted items through their order" do
    @order.save!
    item = @order.order_items.first
    original_quantity = item.quantity
    item.quantity = 0

    assert_not @order.save
    assert @order.errors[:order_items].present?
    assert_equal original_quantity, item.reload.quantity
  end

  test "rejects duplicate products in an unsaved order" do
    @order.order_items.build(product_id: products(:one).id, quantity: 1, unit_price: 500)

    assert @order.order_items.all? { |item| item.order_id.nil? }
    assert_no_difference [ -> { Order.count }, -> { OrderItem.count } ] do
      assert_not @order.save
    end
    assert_includes @order.errors[:order_items], "must not contain duplicate products"
  end

  test "rejects a new item duplicating a persisted product" do
    @order.save!
    @order.reload.order_items.build(product: products(:one), quantity: 1, unit_price: 500)

    assert_not @order.valid?
    assert_includes @order.errors[:order_items], "must not contain duplicate products"
  end

  test "accepts different products in one order" do
    @order.order_items.build(product: products(:two), quantity: 1, unit_price: 0)

    assert @order.save
    assert_equal 2, @order.reload.order_items.count
  end

  test "requires a total amount" do
    [ nil, "", "   " ].each do |value|
      @order.total_amount = value

      assert_not @order.valid?
      assert @order.errors.added?(:total_amount, :blank)
    end
  end

  test "accepts zero total and omitted or zero client total" do
    @order.total_amount = 0

    [ nil, 0 ].each do |value|
      @order.client_total_amount = value

      assert @order.save
      assert_equal 0, @order.reload.total_amount
      if value.nil?
        assert_nil @order.client_total_amount
      else
        assert_equal value, @order.client_total_amount
      end
    end
  end

  test "allows client totals without comparing or calculating totals" do
    @order.client_total_amount = 999

    assert @order.save
    assert_equal 999, @order.reload.client_total_amount
    assert_equal 1000, @order.total_amount
  end

  test "rejects supplied blank client totals instead of treating them as omitted" do
    [ "", "   " ].each do |value|
      @order.client_total_amount = value

      assert_not @order.valid?
      assert @order.errors[:client_total_amount].present?
    end
  end

  test "rejects negative and non integer amounts before type casting" do
    %i[total_amount client_total_amount].each do |attribute|
      [ -1, 1.5, 1.0, "1.5", "1.0", "invalid", "12pesos" ].each do |value|
        @order[attribute] = value

        assert_not @order.valid?, "Expected #{attribute}=#{value.inspect} to be invalid"
        assert @order.errors[attribute].present?
      end
      @order[attribute] = 1000
    end
  end

  test "allows optional dispatch details to remain null" do
    assert @order.save
    @order.reload

    assert_nil @order.last_dispatch_error
    assert_nil @order.dispatched_at
  end

  test "database rejects null required fields without model validations" do
    @order.save!
    %i[restaurant_id order_type customer_name customer_phone total_amount dispatch_status].each do |attribute|
      @order.reload
      assert_raises ActiveRecord::NotNullViolation do
        Order.transaction(requires_new: true) do
          @order.update_columns(attribute => nil)
        end
      end
    end
  end

  test "database rejects a nonexistent restaurant" do
    @order.save!
    assert_raises ActiveRecord::InvalidForeignKey do
      Order.transaction(requires_new: true) do
        @order.update_columns(restaurant_id: -1)
      end
    end
  end

  test "database rejects negative amounts and invalid enum values" do
    @order.save!
    { total_amount: -1, client_total_amount: -1, order_type: 2, dispatch_status: 3 }.each do |attribute, value|
      @order.reload
      error = assert_raises ActiveRecord::StatementInvalid do
        Order.transaction(requires_new: true) do
          @order.update_columns(attribute => value)
        end
      end

      assert_kind_of PG::CheckViolation, error.cause
    end
  end

  test "database allows null optional fields and zero amounts" do
    @order.save!
    assert @order.update_columns(
      delivery_address: nil, client_total_amount: nil, total_amount: 0,
      last_dispatch_error: nil, dispatched_at: nil
    )
    assert @order.update_columns(client_total_amount: 0)
  end
end
