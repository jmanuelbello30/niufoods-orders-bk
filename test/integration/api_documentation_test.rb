require "test_helper"
require "open3"

class ApiDocumentationTest < ActionDispatch::IntegrationTest
  test "documentation UI is public and uses only local resources" do
    get "/api-docs"
    assert_response :redirect
    follow_redirect!
    assert_response :ok
    assert_equal "text/html", response.media_type
    assert_select "#swagger-ui"
    document = Nokogiri::HTML(response.body)
    assets = document.css("script[src], link[href]").map { |element| element["src"] || element["href"] }
    assert_equal [ "./swagger-ui.css", "./favicon-32x32.png", "./swagger-ui-bundle.js",
      "./swagger-ui-standalone-preset.js" ], assets
    config = JSON.parse(response.body[/const config = (.+);/, 1])
    assert_equal false, config.fetch("persistAuthorization")
    assert_nil config.fetch("validatorUrl")
    assert_equal [ { "url" => "/api-docs/v1/openapi.yaml", "name" => "Niu Foods API v1" } ], config.fetch("urls")
    assert_not config.key?("requestInterceptor")
    assert_not config.key?("responseInterceptor")

    assets.each do |path|
      get URI.join("http://www.example.com/api-docs/index.html", path).path
      assert_response :ok
      assert_not_empty response.body
      assert_not_equal "text/html", response.media_type
    end
  end

  test "versioned specification is public and matches the importable file" do
    get "/api-docs/v1/openapi.yaml"
    assert_response :ok
    document = YAML.safe_load(response.body)
    assert_equal YAML.safe_load_file(Rails.root.join("openapi/v1/openapi.yaml")), document
    assert_equal "3.0.3", document.fetch("openapi")
    assert_equal [ "/api/v1/auth/login", "/api/v1/orders" ], document.fetch("paths").keys
  end

  test "production does not load or expose documentation engines" do
    script = <<~RUBY
      require "rack/mock"
      abort "Documentation engines loaded" if defined?(Rswag)
      request = Rack::MockRequest.new(Rails.application)
      %w[/api-docs /api-docs/index.html /api-docs/v1/openapi.yaml /api-docs/swagger-ui-bundle.js].each do |path|
        response = request.get("https://www.example.com\#{path}")
        abort "Documentation exposed: \#{path} (\#{response.status})" unless response.status == 404
      end
    RUBY
    output, errors, status = Open3.capture3(
      { "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1" },
      RbConfig.ruby, Rails.root.join("bin/rails").to_s, "runner", script
    )
    assert status.success?, "Production documentation check failed: #{output}\n#{errors}"
  end
end
