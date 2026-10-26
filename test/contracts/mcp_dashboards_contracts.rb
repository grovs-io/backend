require_relative "first_party_api_contracts"

module ApiContracts
  register_mcp_subclass "Api::V1::Mcp::DashboardsController#index", parent: "Api::V1::DashboardsController#index"
  register_mcp_subclass "Api::V1::Mcp::DashboardsController#create", parent: "Api::V1::DashboardsController#create",
                        request: strict_object(required: [], properties: { "name" => STRING_OR_NULL, "widgets" => JSON_VALUE })
end
