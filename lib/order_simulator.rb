require "json"
require "net/http"
require "time"

class OrderSimulator
  PRODUCT_PRICES = { 1 => 8990, 2 => 7490, 3 => 6990, 4 => 3990, 5 => 4490,
    6 => 3290, 7 => 9990, 8 => 8990, 9 => 1990, 10 => 1590 }.freeze

  attr_reader :summary

  def initialize(api_token: nil, api_base_url: "http://localhost:3000", count: 6, seed: nil, output: $stdout)
    unless api_token.is_a?(String) && !api_token.strip.empty?
      raise ArgumentError, "API_TOKEN is required; set it to the access_token obtained from POST /api/v1/auth/login"
    end
    @api_token = api_token
    unless count.to_s.match?(/\A\d+\z/) && count.to_i.positive?
      raise ArgumentError, "ORDER_COUNT must be a positive integer"
    end
    unless seed.nil? || seed.to_s.match?(/\A[+-]?\d+\z/)
      raise ArgumentError, "RANDOM_SEED must be an integer"
    end
    @uri = URI.parse(api_base_url) if api_base_url.is_a?(String)
    unless @uri.is_a?(URI::HTTP) && !@uri.hostname.to_s.empty? && (1..65535).cover?(@uri.port) &&
        !@uri.userinfo && !@uri.query && !@uri.fragment
      raise ArgumentError, "API_BASE_URL must be an HTTP or HTTPS URL with a host, valid port and no credentials, query or fragment"
    end
    @uri.path = "#{@uri.path.sub(%r{/+\z}, "")}/api/v1/orders"
    @count = count.to_i
    @seed = seed.nil? ? Random.new_seed : Integer(seed.to_s, 10)
    @output = output
  rescue URI::InvalidURIError
    raise ArgumentError, "API_BASE_URL must be a valid HTTP or HTTPS URL"
  end

  def scenarios
    random = Random.new(@seed)
    valid = Array.new(@count) do |index|
      items = PRODUCT_PRICES.keys.sample(random.rand(1..3), random: random).map do |id|
        { product_id: id, quantity: random.rand(1..4) }
      end
      payload = {
        restaurant_id: index / 2 % 3 + 1, order_type: index.even? ? "pickup" : "delivery",
        customer: { name: "Simulation Customer #{index + 1}", phone: "+56000000000" }, items: items
      }
      payload[:delivery_address] = "Fictional Street #{index + 1}" if payload[:order_type] == "delivery"
      payload[:client_total_amount] = items.sum { |item| PRODUCT_PRICES.fetch(item[:product_id]) * item[:quantity] } if index.odd?
      { name: "valid_#{index + 1}", payload: payload, expected_error: nil }
    end
    base = { restaurant_id: 1, order_type: "pickup",
      customer: { name: "Simulation Customer Invalid", phone: "+56000000000" }, items: [ { product_id: 1, quantity: 1 } ] }
    valid + [
      { name: "quantity_zero", payload: base.merge(items: [ { product_id: 1, quantity: 0 } ]),
        expected_error: { field: "items[0].quantity", code: "greater_than" } },
      { name: "product_not_found", payload: base.merge(items: [ { product_id: -1, quantity: 1 } ]),
        expected_error: { field: "items[0].product_id", code: "blank" } },
      { name: "duplicate_product", payload: base.merge(items: [ { product_id: 1, quantity: 1 }, { product_id: 1, quantity: 2 } ]),
        expected_error: { field: "items", code: "invalid", message: "must not contain duplicate products" } },
      { name: "delivery_without_address", payload: base.merge(order_type: "delivery"),
        expected_error: { field: "delivery_address", code: "blank" } },
      { name: "total_mismatch", payload: base.merge(client_total_amount: PRODUCT_PRICES.fetch(1) + 1),
        expected_error: { field: "client_total_amount", code: "total_mismatch" } }
    ]
  end

  def run
    @summary = { created: 0, sent: 0, error: 0, pending: 0, expected_rejections: 0, unexpected_failures: 0 }
    @output.puts("seed=#{@seed} valid_orders=#{@count}")
    scenarios.each do |scenario|
      break if run_scenario(scenario) == :authentication_failure
    end
    @output.puts("Summary #{@summary.map { |key, value| "#{key}=#{value}" }.join(" ")}")
    @summary[:unexpected_failures].zero? ? 0 : 1
  end

  private
    def post(payload)
      http = Net::HTTP.new(@uri.hostname, @uri.port, nil)
      http.use_ssl = @uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      http.open_timeout = 2
      http.read_timeout = 20
      http.write_timeout = 5
      http.max_retries = 0
      request = Net::HTTP::Post.new(@uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{@api_token}"
      request.body = JSON.generate(payload)
      http.request(request)
    end

    def run_scenario(scenario)
      begin
        response = post(scenario.fetch(:payload))
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError,
        Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE,
        Errno::ETIMEDOUT, Errno::EHOSTUNREACH, Errno::ENETUNREACH, EOFError, IOError,
        OpenSSL::SSL::SSLError, Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError => error
        @summary[:unexpected_failures] += 1
        print_result(scenario, nil, nil, "transport_failure #{error.class.name}")
        return
      end

      status = response.code.to_i
      if [ 401, 403 ].include?(status)
        @summary[:unexpected_failures] += 1
        print_result(scenario, status, nil, "authentication_failure")
        @output.puts("Authentication failed: check API_TOKEN and permissions.")
        return :authentication_failure
      end
      begin
        body = JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        @summary[:unexpected_failures] += 1
        print_result(scenario, status, nil, "invalid_response_json")
        return
      end
      data = body["data"] if body.is_a?(Hash)
      errors = body["errors"] if body.is_a?(Hash)
      expected = scenario[:expected_error]
      created = status == 201 && valid_creation?(data, scenario.fetch(:payload))
      if created
        @summary[:created] += 1
        @summary[data.fetch("dispatch_status").to_sym] += 1
      end

      if created && !expected && %w[sent error].include?(data["dispatch_status"]) &&
          (!scenario[:payload].key?(:client_total_amount) || data["total_amount"] == scenario[:payload][:client_total_amount])
        result = data["dispatch_status"] == "error" ? "created_dispatch_error" : "created"
      elsif status == 422 && expected && valid_errors?(errors) &&
          errors.any? { |error| expected.all? { |key, value| error[key.to_s] == value } }
        @summary[:expected_rejections] += 1
        result = "expected_rejection"
      else
        @summary[:unexpected_failures] += 1
        result = "unexpected_response"
      end
      print_result(scenario, status, data, result)
      errors.each { |error| @output.puts("error=#{JSON.generate(error.slice("field", "code", "message"))}") } if valid_errors?(errors)
    end

    def valid_creation?(data, payload)
      unless data.is_a?(Hash) && data["created_at"].is_a?(String) &&
          data["created_at"].match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(?:Z|[+-]\d{2}:\d{2})\z/)
        return false
      end
      begin
        Time.iso8601(data["created_at"])
      rescue ArgumentError
        return false
      end
      %w[id restaurant_id order_type total_amount dispatch_status created_at].all? { |key| data.key?(key) } &&
        data["id"].is_a?(Integer) && data["id"].positive? &&
        data["restaurant_id"].is_a?(Integer) && data["restaurant_id"] == payload[:restaurant_id] &&
        data["order_type"] == payload[:order_type] && data["total_amount"].is_a?(Integer) && data["total_amount"] >= 0 &&
        %w[pending sent error].include?(data["dispatch_status"])
    end

    def valid_errors?(errors)
      errors.is_a?(Array) && !errors.empty? && errors.all? do |error|
        error.is_a?(Hash) && %w[field code message].all? { |key| error[key].is_a?(String) && !error[key].empty? }
      end
    end

    def print_result(scenario, status, data, result)
      data = {} unless data.is_a?(Hash)
      id = data["id"].is_a?(Integer) && data["id"].positive? ? data["id"] : "-"
      total = data["total_amount"].is_a?(Integer) && data["total_amount"] >= 0 ? data["total_amount"] : "-"
      dispatch_status = %w[pending sent error].include?(data["dispatch_status"]) ? data["dispatch_status"] : "-"
      payload = scenario.fetch(:payload)
      @output.puts("scenario=#{scenario[:name]} restaurant=#{payload[:restaurant_id]} order_type=#{payload[:order_type]} " \
        "http=#{status || "-"} id=#{id} total=#{total} dispatch_status=#{dispatch_status} result=#{result}")
      @output.puts("expected_error=#{JSON.generate(scenario[:expected_error])}") if scenario[:expected_error]
    end
end
