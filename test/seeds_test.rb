require "test_helper"

class SeedsTest < ActiveSupport::TestCase
  setup do
    assert Rails.env.test?
    assert_match(/\Aniufoods_orders_test(?:_\d+)?\z/,
      ActiveRecord::Base.connection.select_value("SELECT current_database()"))
    @original_email = ENV.delete("DEMO_USER_EMAIL")
    @original_password = ENV.delete("DEMO_USER_PASSWORD")
  end

  teardown do
    ENV["DEMO_USER_EMAIL"] = @original_email
    ENV["DEMO_USER_PASSWORD"] = @original_password
  end

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

  test "loads the catalog and provisions a normalized demo user from explicit credentials" do
    ENV["DEMO_USER_EMAIL"] = "  DEMO@EXAMPLE.TEST  "
    ENV["DEMO_USER_PASSWORD"] = "seed-password-123"

    output, errors = capture_io do
      assert_difference "User.count", 1 do
        assert_difference "Product.count", 10 do
          assert_difference "Restaurant.count", 3 do
            load Rails.root.join("db/seeds.rb")
          end
        end
      end
    end

    user = User.find_by!(email: "demo@example.test")
    assert user.authenticate("seed-password-123")
    assert_includes output, "Demo user provisioned"
    assert_empty errors
    assert_not_includes output + errors, ENV.fetch("DEMO_USER_PASSWORD")
  end

  test "repeated seeds preserve the existing user attributes password and catalog" do
    ENV["DEMO_USER_EMAIL"] = "demo@example.test"
    ENV["DEMO_USER_PASSWORD"] = "original-password-123"
    capture_io { load Rails.root.join("db/seeds.rb") }
    before = persisted_snapshot
    ENV["DEMO_USER_EMAIL"] = "  DEMO@EXAMPLE.TEST  "
    ENV["DEMO_USER_PASSWORD"] = "different-password-123"

    output, errors = capture_io { load Rails.root.join("db/seeds.rb") }

    assert_equal before, persisted_snapshot
    user = User.find_by!(email: "demo@example.test")
    assert user.authenticate("original-password-123")
    assert_not user.authenticate("different-password-123")
    assert_includes output, "Existing demo user preserved; credentials were not changed"
    assert_empty errors
    assert_not_includes output + errors, "original-password-123"
    assert_not_includes output + errors, "different-password-123"
  end

  test "seeds without credentials skip the user and explain how to provision it" do
    output, errors = capture_io do
      assert_no_difference "User.count" do
        assert_difference "Product.count", 10 do
          assert_difference "Restaurant.count", 3 do
            load Rails.root.join("db/seeds.rb")
          end
        end
      end
    end

    assert_includes output, "Demo user skipped"
    assert_includes output, "DEMO_USER_EMAIL"
    assert_includes output, "DEMO_USER_PASSWORD"
    assert_includes output, "demo_user:provision"
    assert_empty errors
  end

  test "invalid demo configuration fails before any catalog or user writes" do
    [
      [ nil, "seed-password-123" ], [ "demo@example.test", nil ],
      [ "", "seed-password-123" ], [ "demo@example.test", "" ],
      [ "   ", "seed-password-123" ], [ "demo@example.test", "   " ],
      [ "", "" ], [ "   ", "   " ], [ "invalid-email", "seed-password-123" ],
      [ "demo@example.test", "short-key" ], [ "demo@example.test", "a" * 73 ],
      [ "demo@example.test", "\u00e9" * 37 ]
    ].each do |email, password|
      ENV["DEMO_USER_EMAIL"] = email
      ENV["DEMO_USER_PASSWORD"] = password
      before = persisted_snapshot
      error = nil
      statements = []
      subscriber = ->(_name, _start, _finish, _id, payload) { statements << payload.fetch(:sql) }

      output, errors = capture_io do
        ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
          error = assert_raises(DemoUsers::Provision::Error) { load Rails.root.join("db/seeds.rb") }
        end
      end

      assert_equal before, persisted_snapshot
      assert_empty statements.grep(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i)
      assert_match(/Set DEMO_USER_EMAIL and DEMO_USER_PASSWORD|Invalid demo user:/, error.message)
      assert_empty output
      assert_empty errors
      assert_not_includes error.message, password if password.present?
    end
  end

  test "an existing user does not make invalid seed credentials appear successful" do
    User.create!(email: "demo@example.test", password: "original-password-123")
    ENV["DEMO_USER_EMAIL"] = "demo@example.test"
    ENV["DEMO_USER_PASSWORD"] = "short-key"
    before = persisted_snapshot

    output, errors = capture_io do
      assert_raises(DemoUsers::Provision::Error) { load Rails.root.join("db/seeds.rb") }
    end

    assert_equal before, persisted_snapshot
    assert_empty output
    assert_empty errors
  end

  test "demo provisioning is rejected outside development and test before modifying data" do
    ENV["DEMO_USER_EMAIL"] = "demo@example.test"
    ENV["DEMO_USER_PASSWORD"] = "seed-password-123"
    before = persisted_snapshot

    %w[production staging].each do |environment|
      output, errors = capture_io do
        with_rails_environment(environment) do
          error = assert_raises(DemoUsers::Provision::Error) { load Rails.root.join("db/seeds.rb") }
          assert_equal "Demo users can only be provisioned in development or test", error.message
        end
      end
      assert_equal before, persisted_snapshot
      assert_empty output
      assert_empty errors
    end
  end

  test "production seeds without demo credentials keep the ordinary catalog load" do
    output, errors = capture_io do
      with_rails_environment("production") do
        assert_no_difference "User.count" do
          assert_difference "Product.count", 10 do
            assert_difference "Restaurant.count", 3 do
              load Rails.root.join("db/seeds.rb")
            end
          end
        end
      end
    end

    assert_includes output, "Demo user skipped"
    assert_empty errors
  end

  test "a user persistence failure rolls back the catalog and user together" do
    ENV["DEMO_USER_EMAIL"] = "demo@example.test"
    ENV["DEMO_USER_PASSWORD"] = "seed-password-123"
    before = persisted_snapshot
    original_save = User.instance_method(:save!)
    observed_catalog = nil
    User.define_method(:save!) do |*args, **options|
      original_save.bind_call(self, *args, **options)
      observed_catalog = [ Product.where(id: 1..10).count, Restaurant.where(id: 1..3).count, persisted? ]
      errors.add(:base, "Simulated demo user persistence failure")
      raise ActiveRecord::RecordInvalid, self
    end

    output, errors = capture_io do
      error = assert_raises(DemoUsers::Provision::Error) { load Rails.root.join("db/seeds.rb") }
      assert_includes error.message, "Simulated demo user persistence failure"
      assert_not_includes error.message, ENV.fetch("DEMO_USER_PASSWORD")
    end

    assert_equal [ 10, 3, true ], observed_catalog
    assert_equal before, persisted_snapshot
    assert_empty output
    assert_empty errors
  ensure
    User.define_method(:save!, original_save) if original_save
  end

  test "a catalog conflict prevents demo user creation and leaves existing data unchanged" do
    ENV["DEMO_USER_EMAIL"] = "demo@example.test"
    ENV["DEMO_USER_PASSWORD"] = "seed-password-123"
    Product.create!(id: 10, name: "Other Product", sku: "OTHER-SKU", price: 100)
    before = persisted_snapshot

    capture_io do
      assert_raises(ArgumentError) { load Rails.root.join("db/seeds.rb") }
    end

    assert_equal before, persisted_snapshot
  end

  private
    def persisted_snapshot
      [ Product, Restaurant, User ].map { |model| model.order(:id).map(&:attributes) }
    end

    def with_rails_environment(environment)
      original = Rails.method(:env)
      Rails.define_singleton_method(:env) { ActiveSupport::EnvironmentInquirer.new(environment) }
      yield
    ensure
      Rails.define_singleton_method(:env, original)
    end
end
