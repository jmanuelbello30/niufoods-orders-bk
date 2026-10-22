class Order < ApplicationRecord
  belongs_to :restaurant, inverse_of: :orders
  has_many :order_items, inverse_of: :order, autosave: true

  enum :order_type, { pickup: 0, delivery: 1 }, validate: true
  enum :dispatch_status, { pending: 0, sent: 1, error: 2 }, validate: true

  validates :order_type, :customer_name, :customer_phone, :total_amount, :dispatch_status, presence: true
  validates :delivery_address, presence: true, if: :delivery?
  validates :total_amount, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :client_total_amount, numericality: { only_integer: true, greater_than_or_equal_to: 0 },
    unless: -> { client_total_amount_before_type_cast.nil? }
  validates :order_items, presence: true
  validates_associated :order_items
  validate :products_must_be_unique

  private
    def products_must_be_unique
      product_ids = order_items.map(&:product_id).compact

      if product_ids.uniq.size != product_ids.size
        errors.add(:order_items, "must not contain duplicate products")
      end
    end
end
