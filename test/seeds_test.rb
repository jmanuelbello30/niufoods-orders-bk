require "test_helper"

class SeedsTest < ActiveSupport::TestCase
  test "loads the reference catalog and preserves records when repeated" do
    original_product = products(:one).attributes
    original_restaurant = restaurants(:one).attributes

    assert_difference -> { Product.count }, 10 do
      assert_difference -> { Restaurant.count }, 3 do
        load Rails.root.join("db/seeds.rb")
      end
    end

    assert_equal [
      [ 1, "Niu Roll Salmón", "SKU-001", 8990 ],
      [ 2, "California Ebi", "SKU-002", 7490 ],
      [ 3, "Avocado Roll", "SKU-003", 6990 ],
      [ 4, "Nigiri Salmón x2", "SKU-004", 3990 ],
      [ 5, "Gyozas de Pollo x5", "SKU-005", 4490 ],
      [ 6, "Edamame", "SKU-006", 3290 ],
      [ 7, "Bowl Salmón Teriyaki", "SKU-007", 9990 ],
      [ 8, "Bowl Pollo Teriyaki", "SKU-008", 8990 ],
      [ 9, "Bebida 350 ml", "SKU-009", 1990 ],
      [ 10, "Agua Mineral 500 ml", "SKU-010", 1590 ]
    ], Product.where(id: 1..10).order(:id).pluck(:id, :name, :sku, :price)

    assert_equal [
      [ 1, "Niu Foods Providencia", "PROV", "http://localhost:4567/restaurants/PROV/orders" ],
      [ 2, "Niu Foods Las Condes", "LCON", "http://localhost:4567/restaurants/LCON/orders" ],
      [ 3, "Niu Foods Ñuñoa", "NUNO", "http://localhost:4567/restaurants/NUNO/orders" ]
    ], Restaurant.where(id: 1..3).order(:id).pluck(:id, :name, :code, :dispatch_url)

    before_repeat = [ Product.order(:id).map(&:attributes), Restaurant.order(:id).map(&:attributes) ]
    load Rails.root.join("db/seeds.rb")

    assert_equal before_repeat, [ Product.order(:id).map(&:attributes), Restaurant.order(:id).map(&:attributes) ]
    assert_equal original_product, products(:one).reload.attributes
    assert_equal original_restaurant, restaurants(:one).reload.attributes
  end

  test "rejects conflicting IDs SKUs codes or attributes without partial changes" do
    [
      [ Product, { id: 10, name: "Other Product", sku: "OTHER-SKU", price: 100 } ],
      [ Product, { id: 20, name: "Other Product", sku: "SKU-010", price: 100 } ],
      [ Product, { id: 10, name: "Changed Product", sku: "SKU-010", price: 1590 } ],
      [ Restaurant, { id: 3, name: "Other Restaurant", code: "OTHER", dispatch_url: "http://localhost/other" } ],
      [ Restaurant, { id: 20, name: "Other Restaurant", code: "NUNO", dispatch_url: "http://localhost/other" } ]
    ].each do |model, attributes|
      ActiveRecord::Base.transaction(requires_new: true) do
        model.create!(attributes)
        before_load = [ Product.order(:id).map(&:attributes), Restaurant.order(:id).map(&:attributes) ]

        error = assert_raises(ArgumentError) { load Rails.root.join("db/seeds.rb") }

        assert_includes error.message, "Seed conflict for #{model.name}"
        assert_equal before_load, [ Product.order(:id).map(&:attributes), Restaurant.order(:id).map(&:attributes) ]

        raise ActiveRecord::Rollback
      end
    end
  end

  test "adjusts sequences for subsequent automatic IDs including unrelated records" do
    load Rails.root.join("db/seeds.rb")
    product_max_id = Product.maximum(:id)
    restaurant_max_id = Restaurant.maximum(:id)

    product = Product.create!(name: "Next Product", sku: "NEXT-SKU", price: 100)
    restaurant = Restaurant.create!(name: "Next Restaurant", code: "NEXT", dispatch_url: "http://localhost/next")

    assert_operator product.id, :>, product_max_id
    assert_operator restaurant.id, :>, restaurant_max_id
  end
end
