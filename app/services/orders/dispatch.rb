require "json"
require "net/http"

module Orders
  class Dispatch
    def initialize(order)
      @order = order
    end

    def call
      raise ArgumentError, "Order must be persisted" unless @order.persisted?

      @order.reload
      return @order if @order.sent?
      if Order.connection.transaction_open?
        raise ArgumentError, "Dispatch must run outside a database transaction"
      end

      payload = {
        order_id: @order.id, restaurant_id: @order.restaurant_id, order_type: @order.order_type,
        customer: { name: @order.customer_name, phone: @order.customer_phone },
        delivery_address: @order.delivery_address, total_amount: @order.total_amount,
        items: @order.order_items.order(:id).map do |item|
          { product_id: item.product_id, quantity: item.quantity, unit_price: item.unit_price }
        end
      }
      uri = URI.parse(@order.restaurant.dispatch_url)
      error = transmit(uri, JSON.generate(payload))
      @order.update!(
        dispatch_status: error ? :error : :sent,
        dispatched_at: error ? nil : Time.current,
        last_dispatch_error: error
      )
      @order
    end

    private
      def transmit(uri, body)
        http = Net::HTTP.new(uri.hostname, uri.port, nil)
        http.use_ssl = uri.scheme == "https"
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
        http.open_timeout = 2
        http.read_timeout = 5
        http.write_timeout = 5
        http.max_retries = 0
        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request.body = body
        confirmation_error(http.request(request))
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError,
        Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE,
        Errno::ETIMEDOUT, Errno::EHOSTUNREACH, Errno::ENETUNREACH, EOFError, IOError,
        OpenSSL::SSL::SSLError, Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError => error
        "Dispatch transport failed (#{error.class.name})"
      end

      def confirmation_error(response)
        return "Store returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
        return "Empty store confirmation" if response.body.to_s.empty?

        body = JSON.parse(response.body)
        data = body["data"] if body.is_a?(Hash)
        unless data.is_a?(Hash) && data["accepted"] == true &&
            data["order_id"].is_a?(Integer) && data["order_id"] == @order.id &&
            data["restaurant_id"].is_a?(Integer) && data["restaurant_id"] == @order.restaurant_id
          return "Invalid store confirmation"
        end
        nil
      rescue JSON::ParserError
        "Invalid JSON store confirmation"
      end
  end
end
