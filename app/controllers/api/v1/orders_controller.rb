module Api
  module V1
    class OrdersController < ApplicationController
      wrap_parameters false

      rescue_from ActionDispatch::Http::Parameters::ParseError, with: :render_invalid_json

      def index
        orders = Order.preload(:restaurant).order(created_at: :desc, id: :desc)
        render json: { data: orders.map { |order| OrderSerializer.new(order).summary } }, status: :ok
      end

      def show
        order = Order.preload(:restaurant, order_items: :product).find_by(id: request.path_parameters[:id])
        unless order
          return render json: { errors: [ { field: "id", code: "not_found", message: "Order not found" } ] },
            status: :not_found
        end

        render json: { data: OrderSerializer.new(order).detail }, status: :ok
      end

      def create
        request.request_parameters
        return render_invalid_json if request.raw_post.empty?

        # Normalized Rails parameters discard null array entries; inspect the original JSON with Rails' decoder.
        input = ActiveSupport::JSON.decode(request.raw_post)
        errors = structure_errors(input)
        return render json: { errors: errors }, status: :unprocessable_content if errors.any?

        attributes = ActionController::Parameters.new(input).permit(
          :restaurant_id, :order_type, :delivery_address, :client_total_amount,
          customer: [ :name, :phone ], items: [ :product_id, :quantity ]
        ).to_h
        result = Orders::Create.new(attributes).call

        if result.order.persisted?
          Orders::Dispatch.new(result.order).call
          render json: { data: result.order.as_json(only: %i[
            id restaurant_id order_type total_amount dispatch_status created_at
          ]) }, status: :created
        else
          render json: { errors: result.errors }, status: :unprocessable_content
        end
      end

      def retry_dispatch
        order = Order.find_by(id: request.path_parameters[:id])
        unless order
          return render json: { errors: [ { field: "id", code: "not_found", message: "Order not found" } ] },
            status: :not_found
        end
        if order.sent?
          return render json: { errors: [ { field: "dispatch_status", code: "already_sent", message: "Order has already been sent" } ] },
            status: :conflict
        end

        Orders::Dispatch.new(order).call
        render json: { data: order.as_json(only: %i[
          id restaurant_id order_type total_amount client_total_amount dispatch_status created_at
          dispatched_at last_dispatch_error
        ]) }, status: :ok
      end

      private
        def structure_errors(input)
          unless input.is_a?(Hash)
            return [ { field: "base", code: "invalid_structure", message: "must be a JSON object" } ]
          end

          errors = []
          scalar_fields = input.slice("restaurant_id", "delivery_address", "client_total_amount").to_a
          customer = input["customer"]
          if customer.is_a?(Hash)
            customer.slice("name", "phone").each { |field, value| scalar_fields << [ "customer.#{field}", value ] }
          elsif !customer.nil?
            errors << { field: "customer", code: "invalid_structure", message: "must be a JSON object" }
          end

          items = input["items"]
          if items.is_a?(Array)
            items.each_with_index do |item, index|
              if item.is_a?(Hash)
                item.slice("product_id", "quantity").each { |field, value| scalar_fields << [ "items[#{index}].#{field}", value ] }
              else
                errors << { field: "items[#{index}]", code: "invalid_structure", message: "must be a JSON object" }
              end
            end
          elsif !items.nil?
            errors << { field: "items", code: "invalid_structure", message: "must be an Array" }
          end

          scalar_fields.each do |field, value|
            if value.is_a?(Array) || value.is_a?(Hash)
              errors << { field: field, code: "invalid_structure", message: "must be a scalar value" }
            end
          end
          if !input["order_type"].nil? && !input["order_type"].is_a?(String)
            errors << { field: "order_type", code: "invalid_structure", message: "must be a String" }
          end
          errors
        end

        def render_invalid_json
          render json: { errors: [ { field: "base", code: "invalid_json", message: "Malformed JSON body" } ] },
            status: :bad_request
        end
    end
  end
end
