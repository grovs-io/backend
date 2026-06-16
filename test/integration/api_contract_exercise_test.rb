require "test_helper"
require_relative "auth_test_helper"

class ApiContractExerciseTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  PATH_VALUES = {
    "id" => "missing",
    "project_id" => "missing",
    "campaign_id" => "missing",
    "link_id" => "missing",
    "visitor_id" => "missing",
    "path" => "missing",
    "provider" => "google_oauth2",
    "value" => "missing"
  }.freeze

  test "every registered API contract is exercised by at least one routed request" do
    missing = ApiContracts.actions - exercisable_actions
    assert missing.empty?, "No route available to exercise registered contracts:\n  #{missing.sort.join("\n  ")}"

    exercisable_routes.each do |action, route|
      dispatch_contract_smoke_request(action, route)
    rescue ApiContracts::ContractError => e
      raise e.class, "Contract smoke failed for #{action} via #{route.verb} #{route.path.spec}: #{e.message}", e.backtrace
    end
  end

  private

  def exercisable_actions = exercisable_routes.keys

  def exercisable_routes
    Rails.application.routes.routes.each_with_object({}) do |route, routes|
      action = action_for(route)
      next unless action && ApiContracts.registered?(action)
      next if routes.key?(action)

      routes[action] = route
    end
  end

  def action_for(route)
    controller = route.defaults[:controller]
    action = route.defaults[:action]
    return if controller.nil? || action.nil?
    return unless controller.start_with?("api/", "public/")

    "#{controller.split('/').map(&:camelize).join('::')}Controller##{action}"
  end

  def dispatch_contract_smoke_request(action, route)
    verb = route.verb.to_s.delete("^A-Z").downcase
    path = path_for(route)
    headers = headers_for(action)
    params = params_for(action)

    without_event_queue_writes do
      with_smoke_env(action) do
        public_send(verb, path, params: params, headers: headers)
      end
    end
  end

  def path_for(route)
    path = route.path.spec.to_s.sub("(.:format)", "")
    path = path.gsub(/\*([a-z_]+)/) { PATH_VALUES.fetch(Regexp.last_match(1), "missing") }
    path.gsub(/:([a-z_]+)/) { PATH_VALUES.fetch(Regexp.last_match(1), "missing") }
  end

  def headers_for(action)
    host =
      if action.start_with?("Api::V1::Sdk::", "Api::V1::ServerSdkController")
        sdk_host
      elsif action.start_with?("Api::V1::Mcp::")
        "mcp.sqd.link"
      elsif action.start_with?("Public::PublicLinkController")
        "go.sqd.link"
      elsif action.start_with?("Public::")
        "example.sqd.link"
      else
        api_host
      end

    { "Host" => host }
  end

  def params_for(action)
    contract = ApiContracts.contracts.fetch(action)
    sample_for(contract.request)
  end

  def with_smoke_env(action)
    return yield unless action == "Api::V1::Identity::Sso::SessionsController#omniauth_failure"

    original = ENV["SSO_AUTHENTICATION_ENDPOINT"]
    ENV["SSO_AUTHENTICATION_ENDPOINT"] ||= "http://example.test/sso/failure"
    yield
  ensure
    ENV["SSO_AUTHENTICATION_ENDPOINT"] = original
  end

  def without_event_queue_writes(&block)
    EventIngestionService.stub(:log_async, ->(*, **) {}, &block)
  end

  def sample_for(schema)
    return {} if schema.nil? || ApiContracts.unchecked?(schema)
    return {} if schema.empty?

    if schema["oneOf"]
      return sample_for(schema.fetch("oneOf").first)
    end

    case Array(schema["type"]).first
    when "object"
      required = schema.fetch("required", [])
      properties = schema.fetch("properties", {})
      required.index_with { |key| sample_for(properties.fetch(key, {})) }
    when "array"
      []
    when "integer"
      1
    when "number"
      1
    when "boolean"
      true
    when "string"
      sample_string(schema)
    else
      {}
    end
  end

  def sample_string(schema)
    return schema.fetch("enum").first if schema["enum"]

    "contract-smoke"
  end
end
