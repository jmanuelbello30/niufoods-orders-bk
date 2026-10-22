require_relative "../lib/order_simulator"

begin
  simulator = OrderSimulator.new(
    api_base_url: ENV.fetch("API_BASE_URL", "http://localhost:3000"),
    count: ENV.fetch("ORDER_COUNT", "6"),
    seed: ENV["RANDOM_SEED"]
  )
rescue ArgumentError => error
  warn "Invalid configuration: #{error.message}"
  exit 2
end

exit simulator.run
