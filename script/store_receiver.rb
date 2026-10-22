require "bundler/setup"
require "puma"
require_relative "../lib/store_receiver"

port = Integer(ENV.fetch("STORE_PORT", "4567"), 10)
raise ArgumentError, "STORE_PORT must be between 1 and 65535" unless (1..65535).cover?(port)

receiver = StoreReceiver.new(
  mode: ENV.fetch("STORE_MODE", "success"),
  delay_seconds: ENV.fetch("STORE_DELAY_SECONDS", "6")
)
server = Puma::Server.new(receiver)
server.add_tcp_listener("127.0.0.1", port)
%w[INT TERM].each { |signal| Signal.trap(signal) { server.stop } }

$stdout.sync = true
puts "Store receiver listening on http://127.0.0.1:#{port} mode=#{ENV.fetch("STORE_MODE", "success")}"
server.run.join
