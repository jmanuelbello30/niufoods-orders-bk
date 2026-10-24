require "minitest/autorun"
require "stringio"
require_relative "../../lib/order_simulator"
require_relative "../support/http_transport_helper"

class OrderSimulatorTest < Minitest::Test
  include HttpTransportHelper

  PRICES = { 1 => 8990, 2 => 7490, 3 => 6990, 4 => 3990, 5 => 4490,
    6 => 3290, 7 => 9990, 8 => 8990, 9 => 1990, 10 => 1590 }.freeze
  API_TOKEN = "fictional-simulator-token"

  def setup
    @output = StringIO.new
    @simulator = OrderSimulator.new(api_token: API_TOKEN, seed: 42, output: @output)
  end

  def test_scenarios_are_reproducible_and_do_not_share_mutable_results
    original = @simulator.scenarios
    assert_equal original, @simulator.scenarios
    assert_equal original, OrderSimulator.new(api_token: API_TOKEN, seed: "42").scenarios
    original.first[:payload][:items].first[:quantity] = 999
    refute_equal original, @simulator.scenarios
    unseeded = OrderSimulator.new(api_token: API_TOKEN)
    assert_equal unseeded.scenarios, unseeded.scenarios
    refute_equal @simulator.scenarios, OrderSimulator.new(api_token: API_TOKEN, seed: 43).scenarios
  end

  def test_valid_scenarios_cover_restaurants_types_prices_and_fictional_data
    [ 6, 8 ].each do |count|
      valid = OrderSimulator.new(api_token: API_TOKEN, count: count, seed: 42).scenarios.first(count)
      valid.each_with_index do |scenario, index|
        payload = scenario.fetch(:payload)
        assert_equal "valid_#{index + 1}", scenario[:name]
        assert_nil scenario[:expected_error]
        assert payload.keys.all? { |key| key.is_a?(Symbol) }
        assert_equal index / 2 % 3 + 1, payload[:restaurant_id]
        assert_equal index.even? ? "pickup" : "delivery", payload[:order_type]
        assert_equal({ name: "Simulation Customer #{index + 1}", phone: "+56000000000" }, payload[:customer])
        assert_match(/Fictional Street/, payload[:delivery_address]) if index.odd?
        assert_includes 1..3, payload[:items].size
        assert_equal payload[:items].size, payload[:items].map { |item| item[:product_id] }.uniq.size
        payload[:items].each do |item|
          assert_includes PRICES.keys, item[:product_id]
          assert_instance_of Integer, item[:quantity]
          assert_includes 1..4, item[:quantity]
        end
        index.even? ? refute(payload.key?(:client_total_amount)) : assert_equal(total(payload), payload[:client_total_amount])
      end
      assert_equal [ [ 1, "pickup" ], [ 1, "delivery" ], [ 2, "pickup" ], [ 2, "delivery" ],
        [ 3, "pickup" ], [ 3, "delivery" ] ], valid.first(6).map { |s| s[:payload].values_at(:restaurant_id, :order_type) }
    end
  end

  def test_invalid_scenarios_follow_valid_ones_with_precise_expectations
    invalid = @simulator.scenarios.drop(6)
    assert_equal %w[quantity_zero product_not_found duplicate_product delivery_without_address total_mismatch], invalid.map { |s| s[:name] }
    assert_equal [ [ "items[0].quantity", "greater_than" ], [ "items[0].product_id", "blank" ],
      [ "items", "invalid" ], [ "delivery_address", "blank" ], [ "client_total_amount", "total_mismatch" ] ],
      invalid.map { |s| s[:expected_error].values_at(:field, :code) }
    assert_equal 0, invalid[0][:payload][:items][0][:quantity]
    assert_equal(-1, invalid[1][:payload][:items][0][:product_id])
    assert_equal 1, invalid[2][:payload][:items].map { |item| item[:product_id] }.uniq.size
    assert_equal "must not contain duplicate products", invalid[2][:expected_error][:message]
    assert_equal "delivery", invalid[3][:payload][:order_type]
    assert_nil invalid[3][:payload][:delivery_address]
    refute_equal total(invalid[4][:payload]), invalid[4][:payload][:client_total_amount]
  end

  def test_rejects_invalid_configuration_before_any_http_request
    invalid = { api_token: [ nil, "", " \t\n", true, 123 ],
      count: [ 0, -1, 1.5, "1.5", "bad", "", nil, true ], seed: [ "bad", "1.5", 1.5, true ],
      api_base_url: [ nil, "", "ftp://localhost", "http:///", "http://", "http://bad host",
        "http://localhost?x=1", "http://localhost#fragment", "http://user:secret@localhost",
        "http://localhost:0", "http://localhost:65536", "http://localhost:bad" ] }
    with_http_transport(->(*) { flunk "Invalid configuration must not send HTTP" }) do
      invalid.each do |key, values|
        values.each { |value| assert_raises(ArgumentError, "#{key}=#{value.inspect}") { OrderSimulator.new(**{ api_token: API_TOKEN, key => value }) } }
      end
    end
    assert_equal 11, OrderSimulator.new(api_token: API_TOKEN, count: "06", seed: "-12").scenarios.size
    assert_equal 6, OrderSimulator.new(api_token: API_TOKEN, count: 1, seed: "+12").scenarios.size
  end

  def test_success_without_response_client_total_and_expected_rejections_return_zero_and_print_safe_results
    assert_equal 0, run_simulator
    refute_includes @output.string, API_TOKEN
    assert_summary created: 6, sent: 6, expected_rejections: 5
    @simulator.scenarios.each do |scenario|
      line = @output.string.lines.find { |entry| entry.start_with?("scenario=#{scenario[:name]} ") }
      refute_nil line
      %w[restaurant= order_type= http= id= total= dispatch_status= result=].each { |field| assert_includes line, field }
      if scenario[:expected_error]
        scenario[:expected_error].each_value { |value| assert_includes @output.string, value }
      end
      [ scenario[:payload][:customer][:name], scenario[:payload][:customer][:phone],
        scenario[:payload][:delivery_address], JSON.generate(scenario[:payload]) ].compact.each do |value|
        refute_includes @output.string, value
      end
    end
    summary_line = @output.string.lines.find { |line| line.start_with?("Summary") }
    @simulator.summary.each { |key, value| assert_includes summary_line, "#{key}=#{value}" }
  end

  def test_created_dispatch_errors_are_not_unexpected_failures
    assert_equal 0, run_simulator { |scenario| creation_response(scenario, dispatch_status: "error") unless scenario[:expected_error] }
    assert_summary created: 6, error: 6, expected_rejections: 5
  end

  def test_pending_creations_are_counted_but_fail_the_run
    assert_equal 1, run_simulator { |scenario| creation_response(scenario, dispatch_status: "pending") unless scenario[:expected_error] }
    assert_summary created: 6, pending: 6, expected_rejections: 5, unexpected_failures: 6
  end

  def test_unexpectedly_accepted_invalid_scenarios_count_as_created_and_failures
    %w[sent error pending].each do |status|
      assert_equal 1, run_simulator { |scenario| creation_response(scenario, dispatch_status: status) if scenario[:expected_error] }
      assert_summary(**{ created: 11, sent: 6, unexpected_failures: 5 }.merge(status.to_sym => status == "sent" ? 11 : 5))
    end
  end

  def test_wrong_error_fields_codes_and_generic_duplicate_messages_are_rejected
    [ { field: "other" }, { code: "other" }, { message: "is invalid" } ].each do |change|
      assert_equal 1, run_simulator { |scenario|
        rejection_response(scenario, change) if scenario[:name] == "duplicate_product"
      }
      assert_summary created: 6, sent: 6, expected_rejections: 4, unexpected_failures: 1
    end
  end

  def test_every_error_requires_nonempty_string_field_code_and_message
    [ nil, {}, [], [ nil ], [ "error" ] ].concat(
      %i[field code message].flat_map { |key| [ nil, "", 123 ].map { |value| [ { field: "items", code: "invalid", message: "must not contain duplicate products" }.merge(key => value) ] } }
    ).each do |errors|
      assert_equal 1, run_simulator { |scenario|
        http_response(422, JSON.generate(errors: errors)) if scenario[:name] == "duplicate_product"
      }
      assert_equal 1, @simulator.summary[:unexpected_failures]
    end
    assert_equal 1, run_simulator { |scenario|
      http_response(422, JSON.generate(errors: [ scenario[:expected_error], { field: "x", code: "bad", message: "" } ])) if scenario[:name] == "duplicate_product"
    }
  end

  def test_invalid_json_roots_and_data_are_unexpected_without_retries
    [ "", "{", "null", "[]", "true", "123", '"text"', "{}", '{"data":[]}', '{"data":null}' ].each do |body|
      assert_equal 1, run_simulator { http_response(201, body) }
      assert_summary unexpected_failures: 11
    end
  end

  def test_creation_schema_requires_all_fields_and_valid_types
    invalid = { id: [ nil, 0, -1, "1", 1.0 ], restaurant_id: [ nil, 2, "1", 1.0 ],
      order_type: [ nil, "delivery", 0 ], total_amount: [ nil, -1, "0", 0.0 ],
      dispatch_status: [ nil, "unknown" ],
      created_at: [ nil, 123, "", "not-a-date", "2026-99-22T12:00:00.000Z", "2026-10-22T12:00:00.000", "2026-10-22" ] }
    invalid.each do |key, values|
      [ :missing, *values ].each do |value|
        assert_equal 1, run_simulator { |scenario, index|
          if index.zero?
            data = creation_data(scenario)
            value == :missing ? data.delete(key) : data[key] = value
            http_response(201, JSON.generate(data: data))
          end
        }
        assert_summary created: 5, sent: 5, expected_rejections: 5, unexpected_failures: 1
      end
    end
  end

  def test_response_total_must_match_declared_input_total
    [ 0, total(@simulator.scenarios[1][:payload]) + 1 ].each do |amount|
      assert_equal 1, run_simulator { |scenario, index| creation_response(scenario, total_amount: amount) if index == 1 }
      assert_summary created: 6, sent: 6, expected_rejections: 5, unexpected_failures: 1
    end
  end

  def test_api_total_remains_authoritative_when_client_total_is_omitted
    assert_equal 0, run_simulator { |scenario, index| creation_response(scenario, total_amount: 42_001) if index.zero? }

    assert_summary created: 6, sent: 6, expected_rejections: 5
    assert_includes @output.string, "total=42001"
  end

  def test_http_errors_and_redirects_are_never_retried_or_followed
    [ 503, 302 ].each do |code|
      assert_equal 1, run_simulator {
        response = http_response(code, '{"data":{}}')
        response["Location"] = "https://must-not-connect.invalid/orders"
        response
      }
      assert_summary unexpected_failures: 11
    end
  end

  def test_transport_uses_direct_post_json_timeouts_and_verified_https_with_prefix
    @simulator = OrderSimulator.new(api_token: API_TOKEN, api_base_url: "https://localhost:3443/prefix/", seed: 42, output: @output)
    assert_equal 0, run_simulator { |scenario, _index, http, request|
      assert_equal [ "localhost", 3443, nil ], [ http.address, http.port, http.proxy_address ]
      assert http.use_ssl?
      assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
      assert_equal [ 2, 20, 5, 0 ], [ http.open_timeout, http.read_timeout, http.write_timeout, http.max_retries ]
      assert_instance_of Net::HTTP::Post, request
      assert_equal "/prefix/api/v1/orders", request.path
      assert_equal [ "application/json" ] * 2, [ request["Content-Type"], request["Accept"] ]
      assert_equal "Bearer #{API_TOKEN}", request["Authorization"]
      assert_equal JSON.generate(scenario[:payload]), request.body
      nil
    }
  end

  def test_authentication_failures_stop_all_remaining_scenarios_without_printing_response_body
    [ 401, 403 ].product([ 0, 2, 6, 7 ], [ JSON.generate(errors: [ { field: "token", code: "invalid", message: API_TOKEN } ]), "<html>#{API_TOKEN}</html>" ]).each do |status, target, body|
      assert_equal 1, run_simulator(expected_requests: target + 1) { |_scenario, index|
        http_response(status, body) if index == target
      }
      created = [ target, 6 ].min
      assert_summary created: created, sent: created, expected_rejections: [ target - 6, 0 ].max, unexpected_failures: 1
      assert_includes @output.string, "Authentication failed: check API_TOKEN and permissions."
      assert_includes @output.string, "http=#{status}"
      refute_includes @output.string, "invalid_response_json"
      refute_includes @output.string, API_TOKEN
      refute_includes @output.string, body
    end
  end

  def test_expected_transport_exceptions_are_sanitized_and_do_not_stop_later_requests
    [ Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError, Errno::ECONNREFUSED,
      Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE, Errno::ETIMEDOUT, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, EOFError, IOError, OpenSSL::SSL::SSLError, Net::ProtocolError,
      Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError ].each do |error_class|
      assert_equal 1, run_simulator { raise error_class, "secret-phone-address-payload" }
      assert_summary unexpected_failures: 11
      assert_includes @output.string, error_class.name
      refute_includes @output.string, "secret-phone-address-payload"
    end
  end

  def test_programming_exceptions_propagate
    [ NoMethodError, ArgumentError ].each do |error_class|
      with_http_transport(->(*) { raise error_class, "Programming failure" }) do
        assert_raises(error_class) { @simulator.run }
      end
    end
  end

  def test_entry_script_exits_two_for_invalid_constructor_configuration
    saved = ENV.to_h.slice("API_TOKEN", "API_BASE_URL", "ORDER_COUNT", "RANDOM_SEED")
    ENV.update("API_TOKEN" => API_TOKEN, "API_BASE_URL" => "http://localhost:3000", "ORDER_COUNT" => "0", "RANDOM_SEED" => "42")
    with_http_transport(->(*) { flunk "Invalid entry configuration must not send HTTP" }) do
      _stdout, stderr = capture_io do
        assert_equal 2, assert_raises(SystemExit) { load File.expand_path("../../script/simulate_orders.rb", __dir__) }.status
      end
      assert_includes stderr, "Invalid configuration"
      refute_includes stderr, API_TOKEN
    end
  ensure
    %w[API_TOKEN API_BASE_URL ORDER_COUNT RANDOM_SEED].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def test_entry_script_exits_two_without_a_token_before_any_http_request
    saved = ENV.to_h.slice("API_TOKEN", "API_BASE_URL", "ORDER_COUNT", "RANDOM_SEED")
    ENV.update("API_BASE_URL" => "http://localhost:3000", "ORDER_COUNT" => "6", "RANDOM_SEED" => "42")
    with_http_transport(->(*) { flunk "Missing token must not send HTTP or log in" }) do
      [ nil, "", " \t" ].each do |token|
        ENV["API_TOKEN"] = token
        stdout, stderr = capture_io do
          assert_equal 2, assert_raises(SystemExit) { load File.expand_path("../../script/simulate_orders.rb", __dir__) }.status
        end
        assert_empty stdout
      assert_equal "Invalid configuration: API_TOKEN is required; set it to the access_token obtained from POST /api/v1/auth/login\n", stderr
      end
    end
  ensure
    %w[API_TOKEN API_BASE_URL ORDER_COUNT RANDOM_SEED].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  private
    def total(payload)
      payload[:items].sum { |item| PRICES.fetch(item[:product_id], 0) * item[:quantity] }
    end

    def creation_data(scenario)
      payload = scenario[:payload]
      { id: 123, restaurant_id: payload[:restaurant_id], order_type: payload[:order_type],
        total_amount: total(payload),
        dispatch_status: "sent", created_at: "2026-10-22T12:00:00.000Z" }
    end

    def creation_response(scenario, **changes)
      http_response(201, JSON.generate(data: creation_data(scenario).merge(changes)))
    end

    def rejection_response(scenario, changes = {})
      http_response(422, JSON.generate(errors: [ { message: "Validation failed" }.merge(scenario[:expected_error]).merge(changes) ]))
    end

    def run_simulator(expected_requests: @simulator.scenarios.size)
      @output.truncate(0)
      @output.rewind
      scenarios = @simulator.scenarios
      requests = 0
      handler = lambda do |http, request|
        scenario = scenarios.fetch(requests)
        index = requests
        requests += 1
        response = yield(scenario, index, http, request) if block_given?
        response || (scenario[:expected_error] ? rejection_response(scenario) : creation_response(scenario))
      end
      result = with_http_transport(handler) { @simulator.run }
      assert_equal expected_requests, requests
      result
    end

    def assert_summary(**counts)
      expected = { created: 0, sent: 0, error: 0, pending: 0, expected_rejections: 0, unexpected_failures: 0 }.merge(counts)
      assert_equal expected, @simulator.summary
      assert @simulator.summary.values.all? { |value| value.is_a?(Integer) }
    end
end
