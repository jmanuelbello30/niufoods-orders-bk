require "test_helper"

class RestaurantTest < ActiveSupport::TestCase
  setup do
    @restaurant = Restaurant.new(
      name: "Test Restaurant", code: "TEST-NEW", dispatch_url: "https://store.example.com/orders"
    )
  end

  test "persists a valid restaurant" do
    assert @restaurant.save
    assert_equal "Test Restaurant", @restaurant.reload.name
  end

  test "requires name code and dispatch URL" do
    %i[name code dispatch_url].each do |attribute|
      [ nil, "", "   " ].each do |value|
        restaurant = @restaurant.dup
        restaurant[attribute] = value

        assert_not restaurant.valid?
        assert restaurant.errors.added?(attribute, :blank)
      end
    end
  end

  test "requires a unique code" do
    @restaurant.code = restaurants(:one).code

    assert_not @restaurant.valid?
    assert @restaurant.errors.added?(:code, :taken, value: @restaurant.code)
  end

  test "allows keeping the code when updating a restaurant" do
    restaurant = restaurants(:one)

    assert restaurant.update(name: "Updated Restaurant")
  end

  test "accepts HTTP and HTTPS URLs including local destinations" do
    [
      "http://store.example.com/orders",
      "https://store.example.com/orders?source=test",
      "http://localhost:4567/orders",
      "https://localhost/orders",
      "http://127.0.0.1:4567/orders",
      "http://[::1]:4567/orders"
    ].each do |url|
      @restaurant.dispatch_url = url

      assert @restaurant.valid?, "Expected #{url.inspect} to be valid"
    end
  end

  test "rejects malformed URLs non HTTP schemes and URLs without a host" do
    [
      "not a URL",
      "store.example.com/orders",
      "/orders",
      "//store.example.com/orders",
      "ftp://store.example.com/orders",
      "javascript:alert(1)",
      "http://",
      "https:///orders",
      "http://store.example.com:invalid/orders",
      "https://store.example.com/a path"
    ].each do |url|
      @restaurant.dispatch_url = url

      assert_not @restaurant.valid?, "Expected #{url.inspect} to be invalid"
      assert @restaurant.errors[:dispatch_url].present?
    end
  end

  test "database rejects null required fields without model validations" do
    %i[name code dispatch_url].each do |attribute|
      assert_raises ActiveRecord::NotNullViolation do
        Restaurant.transaction(requires_new: true) do
          restaurants(:one).update_columns(attribute => nil)
        end
      end
    end
  end

  test "database rejects duplicate codes without model validations" do
    assert_raises ActiveRecord::RecordNotUnique do
      Restaurant.transaction(requires_new: true) do
        restaurants(:two).update_columns(code: restaurants(:one).code)
      end
    end
  end
end
