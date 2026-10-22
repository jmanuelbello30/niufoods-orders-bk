class Product < ApplicationRecord
  validates :name, :sku, :price, presence: true
  validates :sku, uniqueness: true
  validates :price, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
