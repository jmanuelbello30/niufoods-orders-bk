require "json"
require "rack"
require "set"

class StoreReceiver
  RESTAURANTS = { "PROV" => 1, "LCON" => 2, "NUNO" => 3 }.freeze
  ERROR_MESSAGES = {
    not_found: "Unknown restaurant route",
    method_not_allowed: "Only POST is supported",
    unsupported_media_type: "Content-Type must be application/json",
    invalid_json: "Malformed JSON body",
    invalid_payload: "Invalid dispatch payload",
    invalid_order_id: "order_id must be a positive integer",
    restaurant_mismatch: "restaurant_id does not match the destination restaurant",
    simulated_error: "Simulated store failure"
  }.freeze

  def initialize(mode: "success", delay_seconds: 6, output: $stdout)
    raise ArgumentError, "mode must be success, error or delay" unless %w[success error delay].include?(mode)

    @mode = mode
    @delay_seconds = Float(delay_seconds)
    unless @delay_seconds.finite? && @delay_seconds >= 0
      raise ArgumentError, "delay_seconds must be finite and non-negative"
    end
    @output = output
    @accepted = Set.new
    @mutex = Mutex.new
  end

  def call(env)
    request = Rack::Request.new(env)
    restaurant = request.path_info.match(%r{\A/restaurants/(PROV|LCON|NUNO)/orders\z})&.[](1)
    return response(404, :not_found) unless restaurant
    return response(405, :method_not_allowed, restaurant: restaurant) unless request.post?
    return response(415, :unsupported_media_type, restaurant: restaurant) unless request.media_type == "application/json"

    begin
      payload = JSON.parse(request.body.read)
    rescue JSON::ParserError
      return response(400, :invalid_json, restaurant: restaurant)
    end
    return response(422, :invalid_payload, restaurant: restaurant) unless payload.is_a?(Hash)

    order_id = payload["order_id"]
    return response(422, :invalid_order_id, restaurant: restaurant) unless positive_integer?(order_id)
    unless valid_payload?(payload)
      return response(422, :invalid_payload, restaurant: restaurant, order_id: order_id)
    end
    unless payload["restaurant_id"] == RESTAURANTS.fetch(restaurant)
      return response(422, :restaurant_mismatch, restaurant: restaurant, order_id: order_id)
    end

    key = [ restaurant, order_id ]
    if @mutex.synchronize { @accepted.include?(key) }
      return response(200, :duplicate, restaurant: restaurant, order_id: order_id)
    end
    return response(503, :simulated_error, restaurant: restaurant, order_id: order_id) if @mode == "error"

    sleep @delay_seconds if @mode == "delay"
    duplicate = @mutex.synchronize { !@accepted.add?(key) }
    response(200, duplicate ? :duplicate : :accepted, restaurant: restaurant, order_id: order_id)
  end

  private
    def valid_payload?(payload)
      return false unless positive_integer?(payload["restaurant_id"])
      return false unless %w[pickup delivery].include?(payload["order_type"])
      return false unless payload["total_amount"].is_a?(Integer) && payload["total_amount"] >= 0

      customer = payload["customer"]
      return false unless customer.is_a?(Hash) && customer.values_at("name", "phone").all? { |value| nonblank_string?(value) }

      address = payload["delivery_address"]
      return false unless address.nil? || address.is_a?(String)
      return false if payload["order_type"] == "delivery" && !nonblank_string?(address)

      items = payload["items"]
      items.is_a?(Array) && !items.empty? && items.all? do |item|
        item.is_a?(Hash) && positive_integer?(item["product_id"]) && positive_integer?(item["quantity"]) &&
          item["unit_price"].is_a?(Integer) && item["unit_price"] >= 0
      end
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def nonblank_string?(value)
      value.is_a?(String) && !value.strip.empty?
    end

    def response(status, result, restaurant: nil, order_id: nil)
      @mutex.synchronize do
        @output.puts("restaurant=#{restaurant || "-"} order_id=#{order_id || "-"} result=#{result}")
      end
      if status == 200
        body = { data: { accepted: true, order_id: order_id, restaurant_id: RESTAURANTS.fetch(restaurant), duplicate: result == :duplicate } }
      else
        field = { invalid_order_id: "order_id", restaurant_mismatch: "restaurant_id" }.fetch(result, "base")
        body = { errors: [ { field: field, code: result.to_s, message: ERROR_MESSAGES.fetch(result) } ] }
      end
      headers = { "content-type" => "application/json" }
      headers["allow"] = "POST" if status == 405
      [ status, headers, [ JSON.generate(body) ] ]
    end
end
