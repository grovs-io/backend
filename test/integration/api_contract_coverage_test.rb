require "test_helper"

# Coverage gate for the strict API contract lock (see test/support/api_contracts.rb).
#
# Enumerates every app API endpoint (Controller#action under api/ and public/) and
# asserts each one is EITHER covered by a registered contract OR explicitly listed
# in PENDING below. This makes "all endpoints" enforceable, not aspirational:
#   - add a new endpoint without a contract  -> fails (must contract it or add to PENDING)
#   - write a contract                        -> remove the line from PENDING (else fails)
#   - delete/rename an endpoint               -> stale PENDING entry fails
#
# PENDING is the shrinking backlog. The goal is PENDING == [].
class ApiContractCoverageTest < ActiveSupport::TestCase
  EE_ONLY_ENDPOINTS = %w[
    Api::V1::IapController#apple_prod
    Api::V1::IapController#apple_test
    Api::V1::IapController#google_handling
    Api::V1::PurchasesController#purchases
    Api::V1::PurchasesController#revenue_metrics
  ].freeze

  # No endpoint may sit outside the contract registry. If an endpoint cannot be
  # contracted, the escape hatch belongs in that endpoint's contract with an
  # explicit :any response for the non-JSON/framework-owned case.
  PENDING = [].freeze

  DYNAMIC_SCHEMA_ALLOWLIST = [
    "Api::V1::IapController#apple_prod 200 response",
    "Api::V1::IapController#apple_prod request",
    "Api::V1::IapController#apple_test 200 response",
    "Api::V1::IapController#apple_test request",
    "Api::V1::IapController#google_handling 200 response",
    "Api::V1::IapController#google_handling request",
    "Api::V1::Sdk::PaymentsController#add_payment_event 200 response",
    "Api::V1::Sdk::PaymentsController#add_payment_event request",
    "Api::V1::WebhooksController#stripe_webhook request"
  ].freeze

  NESTED_FLEXIBLE_SCHEMA_ALLOWLIST = [
    "Api::V1::AdminController#create_enterprise_subscription 201 response.properties.subscription.additionalProperties",
    "Api::V1::AdminController#migrate_firebase_links request.properties.file",
    "Api::V1::AdminController#update_enterprise_subscription 200 response.properties.subscription.additionalProperties",
    "Api::V1::AutomationController#details_for_link 200 response.properties.link.properties.data",
    "Api::V1::AutomationController#details_for_link 200 response.properties.link.properties.image",
    "Api::V1::AutomationController#details_for_link request.properties.automation.additionalProperties",
    "Api::V1::AutomationController#metrics_for_user request.properties.automation.additionalProperties",
    "Api::V1::CampaignsController#current_project_campaigns 400 response.properties.traces",
    "Api::V1::CampaignsController#current_project_campaigns_v2 400 response.properties.traces",
    "Api::V1::ConfigurationsController#current_project_configurations 200 response.properties.configurations.items.properties.configuration",
    "Api::V1::ConfigurationsController#set_android_api_access_key request.properties.file",
    "Api::V1::ConfigurationsController#set_android_push_configuration request.properties.push_certificate",
    "Api::V1::ConfigurationsController#set_ios_api_access_key request.properties.file",
    "Api::V1::ConfigurationsController#set_ios_push_configuration request.properties.push_certificate",
    "Api::V1::DashboardController#best_performing_links 200 response.properties.links.items.properties.data",
    "Api::V1::DashboardController#best_performing_links 200 response.properties.links.items.properties.image",
    "Api::V1::DiagnosticsController#test_exception 404 response.oneOf[1].properties.traces",
    "Api::V1::DiagnosticsController#test_exception 500 response.properties.traces",
    "Api::V1::DomainsController#set_project_domain request.properties.generic_image",
    "Api::V1::EventsController#events_sorted_by_param 200 response.oneOf[0].items.properties.link.properties.data",
    "Api::V1::EventsController#events_sorted_by_param 200 response.oneOf[1].properties.result.items.properties.link.properties.data",
    "Api::V1::EventsController#events_sorted_by_param 400 response.properties.traces",
    "Api::V1::LinksController#create_link 200 response.properties.link.properties.data",
    "Api::V1::LinksController#create_link 200 response.properties.link.properties.image",
    "Api::V1::LinksController#create_link 422 response.properties.traces",
    "Api::V1::LinksController#create_link request.properties.android_custom_redirect",
    "Api::V1::LinksController#create_link request.properties.data",
    "Api::V1::LinksController#create_link request.properties.desktop_custom_redirect",
    "Api::V1::LinksController#create_link request.properties.image",
    "Api::V1::LinksController#create_link request.properties.ios_custom_redirect",
    "Api::V1::LinksController#current_project_links 400 response.properties.traces",
    "Api::V1::LinksController#current_project_links_v2 400 response.properties.traces",
    "Api::V1::LinksController#links_by_ids 200 response.properties.links.items.properties.data",
    "Api::V1::LinksController#links_by_ids 200 response.properties.links.items.properties.image",
    "Api::V1::LinksController#update_link 200 response.properties.link.properties.data",
    "Api::V1::LinksController#update_link 200 response.properties.link.properties.image",
    "Api::V1::LinksController#update_link request.properties.android_custom_redirect",
    "Api::V1::LinksController#update_link request.properties.data",
    "Api::V1::LinksController#update_link request.properties.desktop_custom_redirect",
    "Api::V1::LinksController#update_link request.properties.image",
    "Api::V1::LinksController#update_link request.properties.ios_custom_redirect",
    "Api::V1::Mcp::AnalyticsController#link_stats 200 response.properties.metrics",
    "Api::V1::Mcp::AnalyticsController#link_stats 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::AnalyticsController#project_metrics 200 response.properties.metrics",
    "Api::V1::Mcp::AnalyticsController#project_metrics 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::AnalyticsController#top_links 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::AuthController#approve_consent 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::AuthController#usage 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::CampaignsController#archive 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::CampaignsController#create 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::CampaignsController#index 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::ConfigurationsController#setup_redirects 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::ConfigurationsController#setup_sdk 200 response.properties.configurations.additionalProperties.properties.configuration",
    "Api::V1::Mcp::ConfigurationsController#setup_sdk 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::LinksController#archive 200 response.properties.link.properties.data",
    "Api::V1::Mcp::LinksController#archive 200 response.properties.link.properties.image",
    "Api::V1::Mcp::LinksController#archive 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::LinksController#create 201 response.properties.link.properties.data",
    "Api::V1::Mcp::LinksController#create 201 response.properties.link.properties.image",
    "Api::V1::Mcp::LinksController#create 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::LinksController#create request.properties.data",
    "Api::V1::Mcp::LinksController#create request.properties.image",
    "Api::V1::Mcp::LinksController#index 200 response.properties.links.items.properties.data",
    "Api::V1::Mcp::LinksController#index 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::LinksController#show 200 response.properties.link.properties.data",
    "Api::V1::Mcp::LinksController#show 200 response.properties.link.properties.image",
    "Api::V1::Mcp::LinksController#show 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::LinksController#update 200 response.properties.link.properties.data",
    "Api::V1::Mcp::LinksController#update 200 response.properties.link.properties.image",
    "Api::V1::Mcp::LinksController#update 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::LinksController#update request.properties.data",
    "Api::V1::Mcp::LinksController#update request.properties.image",
    "Api::V1::Mcp::ProjectsController#create 400 response.oneOf[1].properties.traces",
    "Api::V1::NotificationsController#notifications 400 response.properties.traces",
    "Api::V1::PaymentsController#subscription_details 200 response.oneOf[0].properties.stripe_subscription.additionalProperties",
    "Api::V1::RedirectsController#redirect_config 200 response.properties.redirect_config.additionalProperties",
    "Api::V1::RedirectsController#set_redirect 200 response.properties.config.additionalProperties",
    "Api::V1::RedirectsController#set_redirect_config 200 response.properties.redirect_config.additionalProperties",
    "Api::V1::Sdk::LinksController#create_link request.properties.android_custom_redirect",
    "Api::V1::Sdk::LinksController#create_link request.properties.data",
    "Api::V1::Sdk::LinksController#create_link request.properties.desktop_custom_redirect",
    "Api::V1::Sdk::LinksController#create_link request.properties.image",
    "Api::V1::Sdk::LinksController#create_link request.properties.ios_custom_redirect",
    "Api::V1::Sdk::LinksController#data_for_device_details 200 response.properties.data",
    "Api::V1::Sdk::LinksController#data_for_device_details_and_path 200 response.properties.data",
    "Api::V1::Sdk::LinksController#data_for_device_details_and_url 200 response.properties.data",
    "Api::V1::Sdk::LinksController#link_details 200 response.properties.data",
    "Api::V1::Sdk::LinksController#link_details 200 response.properties.image",
    "Api::V1::ServerSdkController#generate_link request.properties.android_custom_redirect",
    "Api::V1::ServerSdkController#generate_link request.properties.data",
    "Api::V1::ServerSdkController#generate_link request.properties.desktop_custom_redirect",
    "Api::V1::ServerSdkController#generate_link request.properties.image",
    "Api::V1::ServerSdkController#generate_link request.properties.ios_custom_redirect",
    "Api::V1::ServerSdkController#link_details 200 response.properties.link.properties.data",
    "Api::V1::ServerSdkController#link_details 200 response.properties.link.properties.image",
    "Api::V1::ServerSdkController#metrics_for_link 200 response.properties.metrics.properties.data",
    "Api::V1::ServerSdkController#metrics_for_project 200 response.items.properties.data",
    "Api::V1::UsersController#change_password request.properties.user",
    "Public::PublicLinkController#create request.properties.data",
    "Public::PublicLinkController#create request.properties.image"
  ].freeze

  test "every app API endpoint is contracted or explicitly pending" do
    uncontracted = app_endpoints - ApiContracts.actions

    new_uncovered = (uncontracted - PENDING).sort      # endpoints with no contract and not triaged
    resolved_or_stale = (PENDING - uncontracted).reject { |endpoint| ee_only_endpoint_in_oss_mode?(endpoint) }.sort

    assert new_uncovered.empty? && resolved_or_stale.empty?, <<~MSG
      API contract coverage drift.

      Endpoints with NO contract and NOT in PENDING (add a contract, or add to PENDING):
        #{new_uncovered.empty? ? '(none)' : new_uncovered.join("\n    ")}

      PENDING entries that are now contracted or no longer exist (remove from PENDING):
        #{resolved_or_stale.empty? ? '(none)' : resolved_or_stale.join("\n    ")}

      Locked so far: #{ApiContracts.actions.size}/#{app_endpoints.size} endpoints. Backlog: #{uncontracted.size}.
    MSG
  end

  test "every registered contract maps to a real endpoint" do
    unknown = ApiContracts.actions - app_endpoints
    assert unknown.empty?, "Contracts registered for non-existent endpoints (typo in the key?):\n  #{unknown.join("\n  ")}"
  end

  test "contracts do not use unreviewed broad top-level schemas" do
    loose = ApiContracts.contracts.flat_map do |action, contract|
      entries = []
      entries << "#{action} request" if broad_schema?(contract.request)
      contract.responses.each do |status, schema|
        entries << "#{action} #{status} response" if raw_unchecked?(schema) || broad_schema?(schema)
      end
      entries
    end

    assert loose.empty?, "Broad top-level API contracts must be replaced with endpoint schemas or explicitly allowlisted:\n  #{loose.join("\n  ")}"
  end

  test "dynamic top-level schemas are explicitly allowlisted" do
    dynamic = ApiContracts.contracts.flat_map do |action, contract|
      entries = []
      entries << "#{action} request" if dynamic_schema?(contract.request)
      contract.responses.each do |status, schema|
        entries << "#{action} #{status} response" if dynamic_schema?(schema)
      end
      entries
    end.sort

    unreviewed = dynamic - DYNAMIC_SCHEMA_ALLOWLIST
    stale = DYNAMIC_SCHEMA_ALLOWLIST - dynamic

    assert unreviewed.empty? && stale.empty?, <<~MSG
      Dynamic API contract schema drift.

      Dynamic schemas not allowlisted:
        #{unreviewed.empty? ? '(none)' : unreviewed.join("\n    ")}

      Stale dynamic allowlist entries:
        #{stale.empty? ? '(none)' : stale.join("\n    ")}
    MSG
  end

  test "nested flexible schemas are explicitly allowlisted" do
    flexible = ApiContracts.contracts.flat_map do |action, contract|
      entries = nested_flexible_schema_paths(contract.request, "#{action} request")
      contract.responses.each do |status, schema|
        entries.concat(nested_flexible_schema_paths(schema, "#{action} #{status} response"))
      end
      entries
    end.sort

    unreviewed = flexible - NESTED_FLEXIBLE_SCHEMA_ALLOWLIST
    stale = NESTED_FLEXIBLE_SCHEMA_ALLOWLIST - flexible

    assert unreviewed.empty? && stale.empty?, <<~MSG
      Nested flexible API contract schema drift.

      Flexible nested schemas not allowlisted:
        #{unreviewed.empty? ? '(none)' : unreviewed.join("\n    ")}

      Stale nested flexible allowlist entries:
        #{stale.empty? ? '(none)' : stale.join("\n    ")}
    MSG
  end

  private

  # Controller#action for every app API route (api/ + public/), matching the
  # "controller.class.name#action_name" key the runtime hook uses.
  def app_endpoints
    Rails.application.routes.routes.filter_map do |route|
      defaults = route.defaults
      controller = defaults[:controller]
      action = defaults[:action]
      next if controller.nil? || action.nil?
      next unless controller.start_with?("api/", "public/")

      klass = controller.split("/").map(&:camelize).join("::") + "Controller"
      "#{klass}##{action}"
    end.uniq
  end

  def ee_only_endpoint_in_oss_mode?(endpoint)
    ENV.fetch("GROVS_EE", "false") != "true" && EE_ONLY_ENDPOINTS.include?(endpoint)
  end

  def broad_schema?(schema)
    [ApiContracts::ANY_OBJECT, ApiContracts::JSON_VALUE].include?(schema)
  end

  def raw_unchecked?(schema)
    schema == :any
  end

  def dynamic_schema?(schema)
    defined?(ApiContracts::DYNAMIC_OBJECT_RESPONSE) && [ApiContracts::DYNAMIC_OBJECT_RESPONSE, ApiContracts::DYNAMIC_ARRAY_RESPONSE].include?(schema)
  end

  def nested_flexible_schema_paths(schema, path, nested: false)
    return [] if raw_unchecked?(schema)
    return [path] if nested && broad_schema?(schema)
    return [] unless schema.is_a?(Hash)

    entries = []
    entries << "#{path}.additionalProperties" if nested && schema["additionalProperties"] == true

    schema.fetch("properties", {}).each do |name, property_schema|
      entries.concat(nested_flexible_schema_paths(property_schema, "#{path}.properties.#{name}", nested: true))
    end

    if schema["items"]
      entries.concat(nested_flexible_schema_paths(schema["items"], "#{path}.items", nested: true))
    end

    if schema["additionalProperties"].is_a?(Hash)
      entries.concat(nested_flexible_schema_paths(schema["additionalProperties"], "#{path}.additionalProperties", nested: true))
    end

    %w[oneOf anyOf allOf].each do |keyword|
      Array(schema[keyword]).each_with_index do |subschema, index|
        entries.concat(nested_flexible_schema_paths(subschema, "#{path}.#{keyword}[#{index}]", nested: true))
      end
    end
    entries
  end
end
