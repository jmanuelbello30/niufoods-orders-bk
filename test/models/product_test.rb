require "test_helper"

class ProductTest < ActiveSupport::TestCase
  setup do
    @product = Product.new(name: "Test Product", sku: "TEST-PRODUCT-NEW", price: 4990)
  end

  test "persists a valid product with an integer CLP price" do
    assert @product.save
    assert_equal 4990, @product.reload.price
  end

  test "requires name and SKU" do
    %i[name sku].each do |attribute|
      [ nil, "", "   " ].each do |value|
        product = @product.dup
        product[attribute] = value

        assert_not product.valid?
        assert product.errors.added?(attribute, :blank)
      end
    end
  end

  test "requires a price" do
    [ nil, "", "   " ].each do |value|
      @product.price = value

      assert_not @product.valid?
      assert @product.errors.added?(:price, :blank)
    end
  end

  test "requires a unique SKU" do
    @product.sku = products(:one).sku

    assert_not @product.valid?
    assert @product.errors.added?(:sku, :taken, value: @product.sku)
  end

  test "allows keeping the SKU when updating a product" do
    assert products(:one).update(name: "Updated Product")
  end

  test "accepts a zero price" do
    @product.price = 0

    assert @product.save
    assert_equal 0, @product.reload.price
  end

  test "rejects negative prices" do
    @product.price = -1

    assert_not @product.valid?
    assert @product.errors[:price].present?
  end

  test "rejects non integer prices before type casting" do
    [ 1.5, 1.0, "1.5", "1.0", "invalid", "12pesos" ].each do |value|
      @product.price = value

      assert_not @product.valid?, "Expected #{value.inspect} to be invalid"
      assert @product.errors[:price].present?
    end
  end

  test "database rejects null required fields without model validations" do
    %i[name sku price].each do |attribute|
      assert_raises ActiveRecord::NotNullViolation do
        Product.transaction(requires_new: true) do
          products(:one).update_columns(attribute => nil)
        end
      end
    end
  end

  test "database rejects duplicate SKUs without model validations" do
    assert_raises ActiveRecord::RecordNotUnique do
      Product.transaction(requires_new: true) do
        products(:two).update_columns(sku: products(:one).sku)
      end
    end
  end

  test "database rejects negative prices without model validations" do
    assert_raises ActiveRecord::StatementInvalid do
      Product.transaction(requires_new: true) do
        products(:one).update_columns(price: -1)
      end
    end
  end
end
