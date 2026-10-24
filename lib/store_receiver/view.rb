# frozen_string_literal: true

require "cgi"
require "erb"
require "time"
require "tzinfo"

class StoreReceiver
  class View
    STYLES = File.read(File.join(__dir__, "styles.css"), encoding: "UTF-8").freeze
    TEMPLATE = ERB.new(File.read(File.join(__dir__, "index.erb"), encoding: "UTF-8"), trim_mode: "-")
    TIME_ZONE = TZInfo::Timezone.get("America/Santiago")
    RESTAURANT_NAMES = {
      "PROV" => "Niu Foods Providencia",
      "LCON" => "Niu Foods Las Condes",
      "NUNO" => "Niu Foods Ñuñoa"
    }.freeze
    ORDER_TYPES = { "pickup" => "Retiro en tienda", "delivery" => "Despacho a domicilio" }.freeze

    def initialize(orders)
      @orders = orders
    end

    def render
      TEMPLATE.result(binding)
    end

    private
      def escape(value)
        CGI.escapeHTML(value.to_s)
      end

      def money(amount)
        escape("$ #{amount.to_s.reverse.scan(/.{1,3}/).join('.').reverse} CLP")
      end
  end
end
