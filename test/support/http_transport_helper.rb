require "net/http"

module HttpTransportHelper
  def with_http_transport(handler)
    original = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new) do |*arguments|
      http = original.call(*arguments)
      http.define_singleton_method(:request) { |request| handler.call(http, request) }
      http
    end
    yield
  ensure
    Net::HTTP.define_singleton_method(:new, original)
  end

  def http_response(code, body)
    response = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s).new("1.1", code.to_s, "Test response")
    response["Content-Type"] = "application/json"
    response.define_singleton_method(:body) { body }
    response
  end
end
