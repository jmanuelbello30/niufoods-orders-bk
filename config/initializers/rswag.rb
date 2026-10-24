if Rails.env.development? || Rails.env.test?
  Rswag::Api.configure do |config|
    config.openapi_root = Rails.root.join("openapi").to_s
  end

  Rswag::Ui.configure do |config|
    config.openapi_endpoint "/api-docs/v1/openapi.yaml", "Niu Foods API v1"
    config.config_object[:validatorUrl] = nil
    config.config_object[:persistAuthorization] = false
  end
end
