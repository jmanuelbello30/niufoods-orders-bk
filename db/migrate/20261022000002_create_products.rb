class CreateProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :products do |t|
      t.string :name, null: false
      t.string :sku, null: false
      t.integer :price, null: false

      t.timestamps
    end

    add_index :products, :sku, unique: true
    add_check_constraint :products, "price >= 0", name: "products_price_non_negative"
  end
end
