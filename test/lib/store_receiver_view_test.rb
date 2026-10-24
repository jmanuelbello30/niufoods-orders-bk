require "minitest/autorun"
require "rack/mock"
require "stringio"
require "timeout"
require "nokogiri"
require "time"
require "tzinfo"
require_relative "../../lib/store_receiver"

class StoreReceiverViewTest < Minitest::Test
  def setup
    @output = StringIO.new
    @receiver = StoreReceiver.new(output: @output)
    @threads = []
  end

  def teardown
    @threads.each { |thread| thread.kill if thread.alive? }
    @threads.each(&:join)
  end

  def test_empty_page_and_local_stylesheet_are_read_only_and_not_logged
    before = accepted.dup
    2.times do
      response = get
      assert_equal 200, response.status
      assert_equal "text/html", response.media_type
      assert_equal "no-store", response["cache-control"]
      page = document(response)
      assert_equal "Tienda simulada", page.at_css("title").text
      assert_includes page.text, "Órdenes aceptadas por el receptor local"
      assert_includes page.text, "Aún no hay órdenes aceptadas."
      assert_snapshot page, []
      assert page.at_css('a[href="/"]'), "The page must offer a refresh link"
      stylesheets = page.css('link[rel="stylesheet"]')
      assert_equal [ "/styles.css" ], stylesheets.map { |link| link["href"] }
      assert_empty page.css("script[src], iframe")

      css = get("/styles.css")
      assert_equal 200, css.status
      assert_equal "text/css", css.media_type
      refute_empty css.body.strip
      refute_match(/@import|https?:\/\//i, css.body)
    end
    assert_equal before, accepted
    assert_empty @output.string
  end

  def test_accepted_order_displays_received_values_without_catalog_lookup_or_recalculation
    assert_equal 200, post.status
    page = document(get)
    assert_snapshot page, [ [ "PROV", "123" ] ]
    article = page.at_css("article[data-order-id]")
    [ "PROV", "123", "Despacho a domicilio", "Fictional Customer", "+56000000000",
      "Fictional Avenue 999", "999999", "2", "100", "17" ].each do |value|
      assert_includes article.text, value
    end
    assert_match(/CLP/, article.text)
    cells = article.css("tbody tr").first.css("td").map { |cell| cell.text.strip }
    assert_match(/\b999999\b/, cells.fetch(0))
    assert_equal "2", cells.fetch(1)
    assert_match(/\b100\b.*CLP/, cells.fetch(2))
    refute_includes page.text, "Aún no hay órdenes aceptadas."
    displayed = Time.iso8601(article.at_css("time[datetime]")["datetime"])
    assert_equal accepted.fetch([ "PROV", 123 ]).fetch(:accepted_at).to_i, displayed.to_i
  end

  def test_restaurants_share_order_ids_independently_and_newest_acceptance_is_first
    [ [ "PROV", 1, 900 ], [ "LCON", 2, 900 ], [ "NUNO", 3, 1 ] ].each do |code, id, order_id|
      assert_equal 200, post(payload.merge("restaurant_id" => id, "order_id" => order_id), code: code).status
    end
    assert_snapshot document(get), [ [ "NUNO", "1" ], [ "LCON", "900" ], [ "PROV", "900" ] ]
  end

  def test_pickup_omits_absent_address_and_formats_all_received_prices_in_clp
    body = payload.merge("order_type" => "pickup", "total_amount" => 22_470,
      "items" => [ { "product_id" => 71, "quantity" => 2, "unit_price" => 8990 },
        { "product_id" => 72, "quantity" => 1, "unit_price" => 4490 } ]).reject { |key, _| key == "delivery_address" }
    assert_equal 200, post(body).status
    article = document(get).at_css("article[data-order-id]")
    assert_includes article.text, "Retiro en tienda"
    refute_includes article.text, "Dirección"
    assert_equal [ [ "#71", "2", "$ 8.990 CLP" ], [ "#72", "1", "$ 4.490 CLP" ] ],
      article.css("tbody tr").map { |row| row.css("td").map { |cell| cell.text.strip } }
    assert_equal "$ 22.470 CLP", article.at_css(".order-total strong").text
  end

  def test_changed_duplicate_preserves_original_payload_timestamp_count_and_position
    post
    original = accepted.fetch([ "PROV", 123 ])
    original_time = original.fetch(:accepted_at).dup
    original_payload = Marshal.load(Marshal.dump(original.fetch(:payload)))
    post(payload.merge("order_id" => 124))
    before = get.body
    changed = payload.merge("customer" => { "name" => "Replacement Customer", "phone" => "replacement-phone" },
      "delivery_address" => "Replacement address", "total_amount" => 999,
      "items" => [ { "product_id" => 888_888, "quantity" => 9, "unit_price" => 7 } ])
    response = post(changed)
    assert_equal 200, response.status
    assert_equal true, JSON.parse(response.body).dig("data", "duplicate")
    assert_same original, accepted.fetch([ "PROV", 123 ])
    assert_equal original_time, original.fetch(:accepted_at)
    assert_equal original_payload, original.fetch(:payload)
    assert_equal before, get.body
    assert_snapshot document(get), [ [ "PROV", "124" ], [ "PROV", "123" ] ]
  end

  def test_invalid_requests_and_error_mode_never_appear_as_accepted
    assert_equal 422, post(payload.merge("total_amount" => -1)).status
    assert_equal 422, post(payload.merge("restaurant_id" => 2)).status
    assert_equal 400, post(raw: "{").status
    assert_snapshot document(get), []
    assert_empty accepted

    @receiver = StoreReceiver.new(mode: "error", output: @output)
    2.times { assert_equal 503, post.status }
    assert_snapshot document(get), []
    assert_empty accepted
  end

  def test_delay_leaves_get_available_and_timestamps_only_after_acceptance
    entered, release = controlled_delay
    worker = in_thread { post }
    assert_equal 6.0, within { entered.pop }
    assert_snapshot document(within { get }), []
    assert_empty @output.string
    assert_empty accepted
    assert worker.alive?

    released_at = Time.now.utc
    release << true
    assert_equal 200, within { worker.value }.status
    record = accepted.fetch([ "PROV", 123 ])
    assert record.fetch(:accepted_at).utc?
    assert_operator record.fetch(:accepted_at), :>=, released_at
    assert_operator record.fetch(:accepted_at), :<=, Time.now.utc
    assert_snapshot document(get), [ [ "PROV", "123" ] ]
    assert_equal true, JSON.parse(within { post }.body).dig("data", "duplicate")
    assert entered.empty?, "An accepted duplicate must not wait again"
  end

  def test_sender_giving_up_does_not_cancel_later_acceptance
    entered, release = controlled_delay
    response_ready = Queue.new
    receiver_worker = in_thread { response_ready << post }
    within { entered.pop }
    sender = in_thread { response_ready.pop }
    sender.kill
    sender.join
    assert receiver_worker.alive?, "The receiver must remain independent of the waiting sender"
    assert_snapshot document(within { get }), []
    release << true
    within { receiver_worker.value }
    assert_equal 200, within { response_ready.pop }.status
    assert_snapshot document(get), [ [ "PROV", "123" ] ]
  end

  def test_concurrent_duplicates_and_reads_have_consistent_snapshots_and_preserve_first_payloads
    originals = {}
    [ [ "PROV", 1 ], [ "LCON", 2 ] ].each do |code, id|
      post(payload.merge("restaurant_id" => id), code: code)
      record = accepted.fetch([ code, 123 ])
      originals[[ code, 123 ]] = [ record, Marshal.load(Marshal.dump(record)) ]
    end
    ready = Queue.new
    start = Queue.new
    workers = 12.times.map do |index|
      in_thread do
        ready << true
        start.pop
        code, id = index.even? ? [ "PROV", 1 ] : [ "LCON", 2 ]
        post(payload.merge("restaurant_id" => id, "order_id" => index < 6 ? 123 : 124,
          "customer" => { "name" => "Concurrent #{index}", "phone" => "phone-#{index}" }), code: code)
      end
    end
    reader = in_thread do
      ready << true
      start.pop
      Array.new(30) { get }
    end
    within { 13.times { ready.pop } }
    13.times { start << true }
    responses = within { workers.map(&:value) }
    pages = within { reader.value }
    assert responses.all? { |response| response.status == 200 }
    assert_equal 2, responses.count { |response| JSON.parse(response.body).dig("data", "duplicate") == false }
    pages.each do |response|
      assert_equal 200, response.status
      page = document(response)
      keys = article_keys(page)
      assert_equal keys.uniq, keys
      assert_equal keys.length.to_s, page.at_css("#accepted-count").text.strip
      assert_operator keys.length, :>=, 2
      assert_operator keys.length, :<=, 4
      assert_includes keys, [ "PROV", "123" ]
      assert_includes keys, [ "LCON", "123" ]
    end
    assert_equal 4, accepted.size
    originals.each do |key, (record, copy)|
      assert_same record, accepted.fetch(key)
      assert_equal copy, record
    end
    winning_records = Marshal.load(Marshal.dump(accepted))
    workers = 8.times.map { in_thread { post(payload.merge("order_id" => 124)) } }
    within { workers.each(&:value) }
    assert_equal winning_records, accepted
    assert_equal "4", document(get).at_css("#accepted-count").text.strip
  end

  def test_rendering_does_not_hold_the_acceptance_mutex
    entered = Queue.new
    release = Queue.new
    view_class = StoreReceiver::View
    original_render = view_class.instance_method(:render)
    view_class.define_method(:render) do |*args, **kwargs, &block|
      entered << true
      release.pop
      original_render.bind_call(self, *args, **kwargs, &block)
    end
    reader = in_thread { get }
    within { entered.pop }
    assert_equal 200, within { post }.status
    assert reader.alive?, "Rendering must still be paused while the POST completes"
    release << true
    assert_snapshot document(within { reader.value }), []
  ensure
    release << true if release
    reader.kill if reader&.alive?
    reader&.join
    view_class.define_method(:render, original_render) if original_render
  end

  def test_html_escapes_customer_fields_and_does_not_expose_extra_fields_or_credentials
    malicious = '<script data-injected="true">alert("x")</script>&\' Safe'
    body = payload.merge("customer" => { "name" => malicious, "phone" => malicious,
      "password" => "fictional-customer-password" }, "delivery_address" => malicious,
      "Authorization" => "fictional-payload-authorization", "access_token" => "fictional-access-token",
      "headers" => { "Cookie" => "fictional-cookie" })
    body["items"].first["credential"] = "fictional-item-credential"
    assert_equal 200, post(body, headers: { "HTTP_AUTHORIZATION" => "Bearer fictional-header-token" }).status
    response = get(headers: { "HTTP_AUTHORIZATION" => "Bearer fictional-get-token" })
    page = document(response)
    article = page.at_css("article[data-order-id]")
    assert_equal 3, article.text.scan(malicious).length
    assert_empty page.css("script, [data-injected]")
    refute_includes response.body, malicious
    %w[fictional-customer-password fictional-payload-authorization fictional-access-token
      fictional-cookie fictional-item-credential fictional-header-token fictional-get-token Authorization].each do |secret|
      refute_includes response.body, secret
      refute_includes @output.string, secret
    end
    stored = accepted.fetch([ "PROV", 123 ]).fetch(:payload)
    assert_equal payload.keys.sort, stored.keys.sort
    assert_equal %w[name phone], stored.fetch("customer").keys.sort
    assert_equal %w[product_id quantity unit_price], stored.fetch("items").first.keys.sort
  end

  def test_repeated_gets_preserve_deeply_frozen_accepted_records
    post
    record = accepted.fetch([ "PROV", 123 ])
    before = Marshal.load(Marshal.dump(record))
    logs = @output.string.dup
    first_page = get.body
    3.times { assert_equal first_page, get.body }
    assert_same record, accepted.fetch([ "PROV", 123 ])
    assert_equal before, record
    assert_equal logs, @output.string
    assert_deeply_frozen record
    assert_raises(FrozenError) { record[:accepted_at] = Time.now.utc }
    assert_raises(FrozenError) { record.fetch(:accepted_at).localtime }
    assert_raises(FrozenError) { record.fetch(:payload).fetch("customer").fetch("name").replace("Changed") }
    assert_raises(FrozenError) { record.fetch(:payload).fetch("items").first["quantity"] = 99 }
    assert_raises(FrozenError) { record.fetch(:payload).fetch("items") << {} }
  end

  def test_view_uses_dynamic_santiago_offsets_in_winter_and_summer_without_changing_totals
    zone = TZInfo::Timezone.get("America/Santiago")
    [ [ Time.utc(2026, 7, 15, 15, 30), -4 * 3600 ],
      [ Time.utc(2026, 1, 15, 15, 30), -3 * 3600 ] ].each do |instant, offset|
      record = { restaurant_code: "PROV", accepted_at: instant, payload: payload }
      page = Nokogiri::HTML(StoreReceiver::View.new([ record ]).render)
      article = page.at_css('article[data-order-id="123"][data-restaurant-code="PROV"]')
      time = article.at_css("time[datetime]")
      displayed = Time.iso8601(time["datetime"])
      expected = zone.to_local(instant)
      assert_equal offset, displayed.utc_offset
      assert_equal instant, displayed.utc
      assert_equal expected.strftime("%Y-%m-%dT%H:%M:%S%:z"), Time.iso8601(time["datetime"]).iso8601
      refute_empty time.text.strip
      assert_includes time.text, expected.strftime("%d/%m/%Y %H:%M:%S")
      assert_includes time.text, expected.strftime("%:z")
      assert_match(/\b17\b/, article.text)
      assert_match(/\b100\b/, article.text)
      assert_includes article.text, "CLP"
      assert_equal 17, record.fetch(:payload).fetch("total_amount")
      assert_equal 200, record.fetch(:payload).fetch("items").sum { |item| item.fetch("quantity") * item.fetch("unit_price") }
    end
  end

  private
    def payload
      { "order_id" => 123, "restaurant_id" => 1, "order_type" => "delivery",
        "customer" => { "name" => "Fictional Customer", "phone" => "+56000000000" },
        "delivery_address" => "Fictional Avenue 999", "total_amount" => 17,
        "items" => [ { "product_id" => 999_999, "quantity" => 2, "unit_price" => 100 } ] }
    end

    def post(body = payload, code: "PROV", raw: nil, headers: {})
      env = Rack::MockRequest.env_for("/restaurants/#{code}/orders", method: "POST",
        input: raw || JSON.generate(body))
      env["CONTENT_TYPE"] = "application/json"
      rack_response(env.merge(headers))
    end

    def get(path = "/", headers: {})
      rack_response(Rack::MockRequest.env_for(path, method: "GET").merge(headers))
    end

    def rack_response(env)
      status, headers, chunks = @receiver.call(env)
      Rack::MockResponse.new(status, headers, chunks)
    end

    def document(response)
      Nokogiri::HTML(response.body)
    end

    def article_keys(page)
      page.css("article[data-order-id][data-restaurant-code]").map do |article|
        [ article["data-restaurant-code"], article["data-order-id"] ]
      end
    end

    def assert_snapshot(page, keys)
      assert_equal keys, article_keys(page)
      assert_equal keys.length.to_s, page.at_css("#accepted-count").text.strip
    end

    def accepted
      @receiver.instance_variable_get(:@accepted)
    end

    def controlled_delay
      @receiver = StoreReceiver.new(mode: "delay", delay_seconds: 6, output: @output)
      entered = Queue.new
      release = Queue.new
      @receiver.define_singleton_method(:sleep) do |seconds|
        entered << seconds
        release.pop
      end
      [ entered, release ]
    end

    def in_thread(&block)
      Thread.new(&block).tap { |thread| @threads << thread }
    end

    def within(&block)
      Timeout.timeout(2, &block)
    end

    def assert_deeply_frozen(value)
      assert value.frozen?, "Expected #{value.class} to be frozen"
      case value
      when Hash
        value.each do |key, child|
          assert_deeply_frozen(key)
          assert_deeply_frozen(child)
        end
      when Array
        value.each { |child| assert_deeply_frozen(child) }
      end
    end
end
