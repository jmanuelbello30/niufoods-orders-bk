class OrderSerializer
  def initialize(order)
    @order = order
  end

  def summary
    {
      id: @order.id,
      restaurant_id: @order.restaurant_id,
      restaurant: { id: @order.restaurant.id, name: @order.restaurant.name, code: @order.restaurant.code },
      total_amount: @order.total_amount,
      order_type: @order.order_type,
      created_at: @order.created_at.iso8601(3),
      dispatch_status: @order.dispatch_status
    }
  end

  def detail
    summary.merge(
      client_total_amount: @order.client_total_amount,
      customer: { name: @order.customer_name, phone: @order.customer_phone },
      delivery_address: @order.delivery_address,
      dispatched_at: @order.dispatched_at&.iso8601(3),
      last_dispatch_error: @order.last_dispatch_error,
      items: @order.order_items.sort_by(&:id).map do |item|
        {
          id: item.id, product_id: item.product_id, product_name: item.product.name, sku: item.product.sku,
          quantity: item.quantity, unit_price: item.unit_price, subtotal: item.quantity * item.unit_price
        }
      end
    )
  end
end
