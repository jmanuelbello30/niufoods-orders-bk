class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.references :restaurant, null: false, foreign_key: true
      t.integer :order_type, null: false
      t.string :customer_name, null: false
      t.string :customer_phone, null: false
      t.string :delivery_address
      t.integer :client_total_amount
      t.integer :total_amount, null: false
      t.integer :dispatch_status, null: false, default: 0
      t.text :last_dispatch_error
      t.datetime :dispatched_at

      t.timestamps
    end

    add_check_constraint :orders, "order_type IN (0, 1)", name: "orders_order_type_valid"
    add_check_constraint :orders, "dispatch_status IN (0, 1, 2)", name: "orders_dispatch_status_valid"
    add_check_constraint :orders, "client_total_amount >= 0", name: "orders_client_total_amount_non_negative"
    add_check_constraint :orders, "total_amount >= 0", name: "orders_total_amount_non_negative"
  end
end
