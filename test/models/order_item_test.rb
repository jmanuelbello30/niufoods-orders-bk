require "test_helper"

class OrderItemTest < ActiveSupport::TestCase
  setup do
    @order = Order.new(
      restaurant: restaurants(:one), order_type: :pickup,
      customer_name: "Test Customer", customer_phone: "+56000000003",
      total_amount: 4990, dispatch_status: :pending
    )
    @order_item = @order.order_items.build(product: products(:one), quantity: 1, unit_price: 4990)
  end

  test "accepts an item belonging to an order built in memory" do
    assert @order.new_record?
    assert @order_item.new_record?
    assert_same @order, @order_item.order
    assert @order_item.valid?, @order_item.errors.full_messages.to_sentence
    assert @order.valid?, @order.errors.full_messages.to_sentence
  end

  test "requires an order" do
    @order_item.order = nil

    assert_not @order_item.valid?
    assert @order_item.errors[:order].present?
  end

  test "requires a product" do
    @order_item.product = nil

    assert_not @order_item.valid?
    assert @order_item.errors[:product].present?
  end

  test "rejects a nonexistent order" do
    @order_item.order_id = -1

    assert_not @order_item.valid?
    assert @order_item.errors[:order].present?
  end

  test "rejects a nonexistent product" do
    @order_item.product_id = -1

    assert_not @order_item.valid?
    assert @order_item.errors[:product].present?
  end

  test "requires quantity and unit price" do
    %i[quantity unit_price].each do |attribute|
      [ nil, "", "   " ].each do |value|
        item = @order_item.dup
        item[attribute] = value

        assert_not item.valid?, "Expected #{attribute}=#{value.inspect} to be invalid"
        assert item.errors.added?(attribute, :blank)
      end
    end
  end

  test "rejects zero and negative quantities" do
    [ 0, -1 ].each do |value|
      @order_item.quantity = value

      assert_not @order_item.valid?, "Expected quantity=#{value.inspect} to be invalid"
      assert @order_item.errors[:quantity].present?
    end
  end

  test "rejects non integer quantities and unit prices before type casting" do
    %i[quantity unit_price].each do |attribute|
      [ 1.0, 1.5, "1.0", "1.5", "invalid", "12pesos" ].each do |value|
        item = @order_item.dup
        item[attribute] = value

        assert_not item.valid?, "Expected #{attribute}=#{value.inspect} to be invalid"
        assert item.errors[attribute].present?
      end
    end
  end

  test "accepts a zero unit price" do
    @order_item.unit_price = 0

    assert @order_item.valid?, @order_item.errors.full_messages.to_sentence
  end

  test "rejects negative unit prices" do
    @order_item.unit_price = -1

    assert_not @order_item.valid?
    assert @order_item.errors[:unit_price].present?
  end

  test "rejects a persisted product duplicate within the same order" do
    @order.save!
    duplicate = @order_item.dup
    duplicate.order = @order

    assert_not duplicate.valid?
    assert duplicate.errors.added?(:product_id, :taken, value: products(:one).id)
  end

  test "allows the same product in another order" do
    @order.save!
    other_order = Order.new(
      restaurant: restaurants(:two), order_type: :delivery,
      customer_name: "Test Customer Two", customer_phone: "+56000000002",
      delivery_address: "Test Street 123", total_amount: 4990, dispatch_status: :pending
    )
    other_item = other_order.order_items.build(product: products(:one), quantity: 1, unit_price: 4990)

    assert other_order.save!
    assert_not_equal @order.id, other_order.id
    assert_not_equal @order_item.id, other_item.id
    assert_equal @order, @order_item.reload.order
    assert_equal other_order, other_item.reload.order
    assert_equal products(:one), other_item.product
  end

  test "allows updating an item without changing its references" do
    @order.save!

    assert @order_item.update(quantity: 2), @order_item.errors.full_messages.to_sentence
    assert_equal 2, @order_item.reload.quantity
    assert_equal @order, @order_item.order
    assert_equal products(:one), @order_item.product
  end

  test "database rejects null references and required fields without model validations" do
    @order.save!

    %i[order_id product_id quantity unit_price].each do |attribute|
      @order_item.reload

      assert_raises ActiveRecord::NotNullViolation do
        OrderItem.transaction(requires_new: true) do
          @order_item.update_columns(attribute => nil)
        end
      end
    end
  end

  test "database rejects nonexistent references without model validations" do
    @order.save!

    %i[order_id product_id].each do |attribute|
      @order_item.reload

      assert_raises ActiveRecord::InvalidForeignKey do
        OrderItem.transaction(requires_new: true) do
          @order_item.update_columns(attribute => -1)
        end
      end
    end
  end

  test "database rejects zero and negative quantities without model validations" do
    @order.save!

    [ 0, -1 ].each do |value|
      @order_item.reload

      error = assert_raises ActiveRecord::StatementInvalid do
        OrderItem.transaction(requires_new: true) do
          @order_item.update_columns(quantity: value)
        end
      end

      assert_instance_of PG::CheckViolation, error.cause
    end
  end

  test "database rejects negative unit prices without model validations" do
    @order.save!
    @order_item.reload

    error = assert_raises ActiveRecord::StatementInvalid do
      OrderItem.transaction(requires_new: true) do
        @order_item.update_columns(unit_price: -1)
      end
    end

    assert_instance_of PG::CheckViolation, error.cause
  end

  test "database rejects duplicate products within an order without model validations" do
    @order.save!
    @order_item.reload
    other_item = @order.order_items.create!(product: products(:two), quantity: 1, unit_price: 0)

    assert_raises ActiveRecord::RecordNotUnique do
      OrderItem.transaction(requires_new: true) do
        other_item.update_columns(product_id: @order_item.product_id)
      end
    end
  end
end
