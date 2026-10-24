require "test_helper"
require "openapi_parser"

class OpenapiTest < ActiveSupport::TestCase
  setup do
    @document = YAML.safe_load_file(Rails.root.join("openapi/v1/openapi.yaml"))
    @schema = OpenAPIParser.parse(@document.deep_dup, strict_reference_validation: true)
    @login = @document.fetch("paths").fetch("/api/v1/auth/login").fetch("post")
    @orders = @document.fetch("paths").fetch("/api/v1/orders").fetch("post")
  end

  test "contains exactly the supported operations and opaque Bearer authorization" do
    assert_equal "3.0.3", @document.fetch("openapi")
    assert_equal [ { "url" => "/" } ], @document.fetch("servers")
    assert_equal [ "/api/v1/auth/login", "/api/v1/orders" ], @document.fetch("paths").keys
    assert @document.fetch("paths").values.all? { |path| path.keys == [ "post" ] }
    assert_equal 2, [ @login, @orders ].pluck("operationId").uniq.size
    assert_equal [], @login.fetch("security")
    assert_equal [ { "BearerAuth" => [] } ], @orders.fetch("security")
    assert_equal [ "200" ], @login.fetch("responses").keys
    assert_equal [ "201" ], @orders.fetch("responses").keys
    [ @login, @orders ].each do |operation|
      assert_not operation.key?("description")
      response = operation.fetch("responses").values.sole
      media = response.fetch("content").fetch("application/json")
      assert media.key?("example")
      assert_not media.key?("examples")
    end
    scheme = @document.dig("components", "securitySchemes", "BearerAuth")
    assert_equal "http", scheme.fetch("type")
    assert_equal "bearer", scheme.fetch("scheme")
    assert_not scheme.key?("bearerFormat")
  end

  test "all response examples conform to their schemas with resolved references" do
    @document.fetch("paths").each do |path, methods|
      operation = @schema.request_operation(:post, path)
      methods.fetch("post").fetch("responses").each do |status, response|
        response = resolve(response)
        media = response.fetch("content").fetch("application/json")
        values = media.key?("example") ? [ media.fetch("example") ] : media.fetch("examples").values.pluck("value")
        assert_not_empty values
        values.each do |value|
          body = OpenAPIParser::RequestOperation::ValidatableResponseBody.new(
            status.to_i, value.deep_dup, { "Content-Type" => "application/json" }
          )
          assert operation.validate_response_body(body), "Invalid response example for #{path} #{status}"
        end
      end
    end
  end

  test "declared total remains an input but is absent from the creation response" do
    schemas = @document.fetch("components").fetch("schemas")
    assert schemas.fetch("OrderAttributes").fetch("properties").key?("client_total_amount")
    created_order = schemas.fetch("CreatedOrder")
    assert_not created_order.fetch("properties").key?("client_total_amount")
    assert_not_includes created_order.fetch("required"), "client_total_amount"
    example = @orders.dig("responses", "201", "content", "application/json", "example", "data")
    assert_not example.key?("client_total_amount")
  end

  test "valid requests conform and only structurally invalid examples fail schema validation" do
    login = @schema.request_operation(:post, "/api/v1/auth/login")
    assert login.validate_request_body("application/json", @login.dig("requestBody", "content", "application/json", "example").deep_dup)
    operation = @schema.request_operation(:post, "/api/v1/orders")
    examples = @orders.dig("requestBody", "content", "application/json", "examples")
    assert_equal 12, examples.size
    invalid = {
      "missing_delivery_address" => [ OpenAPIParser::NotOneOf, "isn't one of" ],
      "empty_items" => [ OpenAPIParser::LessThanMinItems, "items" ],
      "invalid_quantity" => [ OpenAPIParser::LessThanMinimum, "quantity" ],
      "invalid_order_type" => [ OpenAPIParser::NotEnumInclude, "order_type" ],
      "incomplete_customer" => [ OpenAPIParser::NotExistRequiredKey, "name" ]
    }
    examples.each do |name, example|
      value = example.fetch("value").deep_dup
      if invalid.key?(name)
        error_class, message = invalid.fetch(name)
        error = assert_raises(error_class) { operation.validate_request_body("application/json", value) }
        assert_includes error.message, message
      else
        # References, repeated products and total equality require API integration tests.
        assert operation.validate_request_body("application/json", value), name
      end
    end
  end

  test "nullable totals and pickup addresses remain optional without weakening delivery" do
    operation = @schema.request_operation(:post, "/api/v1/orders")
    payload = @orders.dig("requestBody", "content", "application/json", "examples", "pickup_simple", "value").deep_dup
    assert operation.validate_request_body("application/json", payload.merge("client_total_amount" => nil, "delivery_address" => nil))
    assert operation.validate_request_body("application/json", payload.merge("extra_field" => "ignored"))
    assert_raises(OpenAPIParser::NotOneOf) do
      operation.validate_request_body("application/json", payload.merge("order_type" => "delivery", "delivery_address" => nil))
    end
    assert_raises(OpenAPIParser::LessThanMinimum) do
      operation.validate_request_body("application/json", payload.merge("client_total_amount" => -1))
    end
  end

  private
    def resolve(value)
      return value unless value.key?("$ref")

      value.fetch("$ref").delete_prefix("#/").split("/").reduce(@document) { |node, key| node.fetch(key) }
    end
end
