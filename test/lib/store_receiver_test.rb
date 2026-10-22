require "minitest/autorun"
require "rack/mock"
require "stringio"
require "timeout"
require_relative "../../lib/store_receiver"

class StoreReceiverTest < Minitest::Test
  def setup
    @output = StringIO.new
    @receiver = StoreReceiver.new(output: @output)
  end

  def test_accepts_each_restaurant_without_recalculating_totals_or_looking_up_products
    { "PROV" => 1, "LCON" => 2, "NUNO" => 3 }.each do |code, id|
      response = request(payload.merge("restaurant_id" => id), code: code)
      assert_equal 200, response.status
      assert_equal({ "data" => { "accepted" => true, "order_id" => 123,
        "restaurant_id" => id, "duplicate" => false } }, JSON.parse(response.body))
      assert_equal "application/json", response.media_type
    end
    assert_equal %w[PROV LCON NUNO].map { |code| "restaurant=#{code} order_id=123 result=accepted\n" }.join, @output.string
  end

  def test_repeated_order_is_a_duplicate_with_only_one_acceptance_log
    first = request
    second = request
    assert_equal 200, second.status
    assert_equal JSON.parse(first.body).fetch("data").merge("duplicate" => true), JSON.parse(second.body).fetch("data")
    assert_equal [ "restaurant=PROV order_id=123 result=accepted\n",
      "restaurant=PROV order_id=123 result=duplicate\n" ], @output.string.lines
  end

  def test_different_order_ids_are_accepted_independently
    [ 123, 124 ].each do |id|
      response = request(payload.merge("order_id" => id))
      assert_equal 200, response.status
      assert_equal false, JSON.parse(response.body).dig("data", "duplicate")
    end
  end

  def test_concurrent_retries_accept_exactly_once
    ready = Queue.new
    start = Queue.new
    threads = Array.new(10) do
      Thread.new do
        ready << true
        start.pop
        request
      end
    end
    responses = Timeout.timeout(1) do
      10.times { ready.pop }
      10.times { start << true }
      threads.map(&:value)
    end
    assert_equal [ 200 ] * 10, responses.map(&:status)
    duplicates = responses.map { |response| JSON.parse(response.body).dig("data", "duplicate") }
    assert_equal 1, duplicates.count(false)
    assert_equal 9, duplicates.count(true)
    assert_equal 1, @output.string.lines.count("restaurant=PROV order_id=123 result=accepted\n")
    assert_equal 9, @output.string.lines.count("restaurant=PROV order_id=123 result=duplicate\n")
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
  end

  def test_accepts_delivery_and_pickup_address_variants_and_zero_amounts
    [ [ "delivery", "Fictional Avenue 999" ], [ "pickup", nil ], [ "pickup", "" ],
      [ "pickup", "Fictional Avenue 999" ] ].each_with_index do |(type, address), index|
      body = payload.merge("order_id" => index + 1, "order_type" => type,
        "delivery_address" => address, "total_amount" => 0,
        "items" => [ { "product_id" => 999_999, "quantity" => 1, "unit_price" => 0 } ])
      assert_equal 200, request(body).status
    end
  end

  def test_rejects_malformed_json_and_non_object_roots
    [ "{", "", '{"order_id":' ].each do |body|
      assert_error request(raw: body), 400, "invalid_json"
    end
    [ false, nil, [], [ payload ], "text", 123, true ].each do |body|
      assert_error request(body), 422, "invalid_payload"
    end
  end

  def test_rejects_missing_or_invalid_order_ids_without_logging_their_values
    [ nil, 0, -1, 1.5, "private-order-id", true, [], {} ].each do |id|
      assert_error request(payload.merge("order_id" => id)), 422, "invalid_order_id", "order_id"
      assert_equal "restaurant=PROV order_id=- result=invalid_order_id\n", @output.string.lines.last
    end
    assert_error request(payload.reject { |key, _| key == "order_id" }), 422, "invalid_order_id", "order_id"
    refute_includes @output.string, "private-order-id"
  end

  def test_rejects_missing_required_payload_fields
    %w[restaurant_id order_type customer total_amount items].each do |field|
      assert_error request(payload.reject { |key, _| key == field }), 422, "invalid_payload"
    end
  end

  def test_rejects_invalid_payload_fields
    invalid_values = {
      "restaurant_id" => [ nil, 0, -1, 1.0, "1", true ],
      "order_type" => [ nil, "", "PICKUP", "other", 0 ],
      "customer" => [ nil, [], "customer", {}, { "name" => "Test" }, { "phone" => "123" },
        { "name" => " \t", "phone" => "123" }, { "name" => 1, "phone" => "123" },
        { "name" => "Test", "phone" => "\n" }, { "name" => "Test", "phone" => false } ],
      "delivery_address" => [ false, 123, [], {} ],
      "total_amount" => [ nil, -1, 0.5, "0", false ],
      "items" => [ nil, {}, [], [ nil ], [ "item" ], [ {} ] ]
    }
    invalid_values.each do |field, values|
      values.each { |value| assert_error request(payload.merge(field => value)), 422, "invalid_payload" }
    end
    [ nil, "", " \t" ].each do |address|
      assert_error request(payload.merge("order_type" => "delivery", "delivery_address" => address)), 422, "invalid_payload"
    end
  end

  def test_rejects_missing_or_invalid_item_fields_in_every_item
    item = payload.fetch("items").first
    { "product_id" => [ nil, 0, -1, 1.5, "1", true ],
      "quantity" => [ nil, 0, -1, 1.5, "1", true ],
      "unit_price" => [ nil, -1, 1.5, "1", true ] }.each do |field, values|
      invalid_items = [ item.reject { |key, _| key == field } ] + values.map { |value| item.merge(field => value) }
      invalid_items.each do |invalid_item|
        assert_error request(payload.merge("items" => [ item, invalid_item ])), 422, "invalid_payload"
      end
    end
  end

  def test_rejects_mismatched_and_unknown_positive_restaurant_ids
    [ 2, 3, 999_999 ].each do |id|
      assert_error request(payload.merge("restaurant_id" => id)), 422, "restaurant_mismatch", "restaurant_id"
    end
    assert_equal 200, request.status
  end

  def test_unknown_routes_return_json_not_found
    [ "/", "/restaurants/UNKNOWN/orders", "/restaurants/999/orders", "/restaurants/prov/orders",
      "/restaurants/PROV/orders/", "/restaurants/PROV/orders/123" ].each do |path|
      assert_error request(path: path), 404, "not_found"
    end
  end

  def test_other_methods_return_json_and_allow_post
    %w[GET PUT PATCH DELETE OPTIONS HEAD].each do |method|
      response = request(method: method)
      assert_error response, 405, "method_not_allowed"
      assert_equal "POST", response["allow"]
    end
  end

  def test_requires_json_media_type_and_accepts_charset_parameter
    [ nil, "text/plain", "application/x-www-form-urlencoded" ].each do |type|
      assert_error request(content_type: type), 415, "unsupported_media_type"
    end
    assert_equal 200, request(content_type: "application/json; charset=utf-8").status
  end

  def test_error_mode_never_accepts_retries
    @receiver = StoreReceiver.new(mode: "error", output: @output)
    2.times { assert_error request, 503, "simulated_error" }
    assert_equal [ "restaurant=PROV order_id=123 result=simulated_error\n" ] * 2, @output.string.lines
  end

  def test_delay_accepts_only_after_sleep_and_duplicates_do_not_sleep_again
    @receiver = StoreReceiver.new(mode: "delay", delay_seconds: 0.01, output: @output)
    entered = Queue.new
    release = Queue.new
    @receiver.define_singleton_method(:sleep) do |seconds|
      entered << seconds
      release.pop
    end
    worker = Thread.new { request }
    Timeout.timeout(1) { assert_equal 0.01, entered.pop }
    assert_empty @output.string
    assert worker.alive?
    release << true
    first = Timeout.timeout(1) { worker.value }
    assert_equal 200, first.status
    assert_equal false, JSON.parse(first.body).dig("data", "duplicate")
    duplicate = Timeout.timeout(1) { request }
    assert_equal 200, duplicate.status
    assert_equal true, JSON.parse(duplicate.body).dig("data", "duplicate")
    assert entered.empty?, "A duplicate must not sleep again"
    assert_equal %w[accepted duplicate], @output.string.lines.map { |line| line.split("result=").last.strip }
  ensure
    worker&.kill if worker&.alive?
    worker&.join
  end

  def test_rejects_invalid_configuration_and_accepts_zero_delay
    [ nil, "unknown", :success, "" ].each do |mode|
      assert_raises(ArgumentError) { StoreReceiver.new(mode: mode, output: @output) }
    end
    [ -1, Float::INFINITY, -Float::INFINITY, Float::NAN, "invalid" ].each do |delay|
      assert_raises(ArgumentError) { StoreReceiver.new(delay_seconds: delay, output: @output) }
    end
    @receiver = StoreReceiver.new(mode: "delay", delay_seconds: 0, output: @output)
    assert_equal 200, request.status
  end

  def test_logs_never_include_customer_details_or_payloads_on_success_duplicate_or_error
    request
    request
    assert_error request(payload.merge("total_amount" => -1)), 422, "invalid_payload"
    @receiver = StoreReceiver.new(mode: "error", output: @output)
    assert_error request, 503, "simulated_error"
    [ payload.dig("customer", "name"), payload.dig("customer", "phone"),
      payload.fetch("delivery_address"), JSON.generate(payload), "customer", "items", "total_amount" ].each do |private_value|
      refute_includes @output.string, private_value
    end
    assert_equal %w[accepted duplicate invalid_payload simulated_error].map { |result|
      "restaurant=PROV order_id=123 result=#{result}\n"
    }.join, @output.string
  end

  private
    def payload
      { "order_id" => 123, "restaurant_id" => 1, "order_type" => "pickup",
        "customer" => { "name" => "Fictional Customer", "phone" => "+56000000000" },
        "delivery_address" => "Fictional Avenue 999", "total_amount" => 17,
        "items" => [ { "product_id" => 999_999, "quantity" => 2, "unit_price" => 100 } ] }
    end

    def request(body = payload, code: "PROV", path: nil, method: "POST", content_type: "application/json", raw: nil)
      env = Rack::MockRequest.env_for(path || "/restaurants/#{code}/orders",
        method: method, input: raw ? raw.dup : JSON.generate(body))
      env["CONTENT_TYPE"] = content_type if content_type
      status, headers, chunks = @receiver.call(env)
      Rack::MockResponse.new(status, headers, chunks)
    end

    def assert_error(response, status, code, field = "base")
      messages = {
        "not_found" => "Unknown restaurant route", "method_not_allowed" => "Only POST is supported",
        "unsupported_media_type" => "Content-Type must be application/json", "invalid_json" => "Malformed JSON body",
        "invalid_payload" => "Invalid dispatch payload", "invalid_order_id" => "order_id must be a positive integer",
        "restaurant_mismatch" => "restaurant_id does not match the destination restaurant",
        "simulated_error" => "Simulated store failure"
      }
      assert_equal status, response.status
      assert_equal "application/json", response.media_type
      assert_equal({ "errors" => [ { "field" => field, "code" => code, "message" => messages.fetch(code) } ] },
        JSON.parse(response.body))
      assert_match(/\Arestaurant=(?:PROV|LCON|NUNO|-) order_id=(?:[1-9]\d*|-) result=#{code}\n\z/, @output.string.lines.last)
    end
end
