module Orders
  class Create
    attr_reader :order

    def initialize(attributes)
      @attributes = attributes.is_a?(Hash) ? attributes.deep_symbolize_keys : attributes
    end

    def call
      @order = Order.new(total_amount: 0)
      unless @attributes.is_a?(Hash)
        order.errors.add(:base, :invalid_structure, message: "must be a Hash")
        return self
      end

      customer = @attributes[:customer]
      items = @attributes[:items]
      unless customer.nil? || customer.is_a?(Hash)
        order.errors.add(:base, :invalid_structure, field: "customer", message: "must be a Hash")
      end
      unless items.nil? || items.is_a?(Array)
        order.errors.add(:base, :invalid_structure, field: "items", message: "must be an Array")
      end
      if items.is_a?(Array)
        items.each_with_index do |item, index|
          unless item.is_a?(Hash)
            order.errors.add(:base, :invalid_structure, field: "items[#{index}]", message: "must be a Hash")
          end
        end
      end
      return self if order.errors.any?

      customer ||= {}
      order.assign_attributes(
        restaurant: Restaurant.find_by(id: @attributes[:restaurant_id]),
        order_type: @attributes[:order_type],
        customer_name: customer[:name],
        customer_phone: customer[:phone],
        delivery_address: @attributes[:delivery_address],
        client_total_amount: @attributes[:client_total_amount]
      )

      (items || []).each do |attributes|
        product = Product.find_by(id: attributes[:product_id])
        order.order_items.build(product: product, quantity: attributes[:quantity], unit_price: product&.price)
      end

      # Validate all input before using cast quantities or comparing a calculated total.
      return self unless order.valid?

      order.total_amount = order.order_items.sum { |item| item.quantity * item.unit_price }
      if !order.client_total_amount.nil? && order.client_total_amount != order.total_amount
        order.errors.add(:client_total_amount, :total_mismatch,
          message: "Declared total #{order.client_total_amount} CLP does not match calculated total #{order.total_amount} CLP")
        return self
      end

      Order.transaction(requires_new: true) { order.save! }
      self
    end

    def errors
      return [] unless order

      fields = {
        restaurant: "restaurant_id", customer_name: "customer.name", customer_phone: "customer.phone",
        order_items: "items", product: "product_id"
      }
      records = [ [ order, "" ] ] + order.order_items.each_with_index.map { |item, index| [ item, "items[#{index}]." ] }

      records.flat_map do |record, prefix|
        record.errors.filter_map do |error|
          next if error.attribute.to_s.start_with?("order_items.")

          {
            field: error.options[:field] || "#{prefix}#{fields.fetch(error.attribute, error.attribute.to_s)}",
            code: error.type.is_a?(Symbol) ? error.type.to_s : "invalid",
            message: error.message
          }
        end
      end
    end
  end
end
