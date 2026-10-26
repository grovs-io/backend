require_relative "../../../test/contracts/first_party_api_contracts"
require_relative "segment_contracts"
require_relative "push_campaign_contracts"
require_relative "in_app_contracts"
require_relative "journey_contracts"

module ApiContracts
  MCP_EXPERIMENT_OR_NONE = strict_object(required: %w[experiment],
                                         properties: { "experiment" => { "anyOf" => [EXPERIMENT, { "type" => "null" }] },
                                                       "_warning" => STRING_OR_NULL })

  {
    "SegmentsController" => %w[index fields estimate create],
    "PushCampaignsController" => %w[index show],
    "InAppCampaignsController" => %w[index show report comments],
    "JourneysController" => %w[index report]
  }.each do |controller, actions|
    actions.each { |a| register_mcp_subclass "Api::V1::Mcp::#{controller}##{a}", parent: "Api::V1::#{controller}##{a}" }
  end
  register_mcp_subclass "Api::V1::Mcp::SegmentsController#breakdown", parent: "Api::V1::SegmentsController#breakdown",
                                                                       responses: { 400 => MCP_FIELD_NOT_ALLOWED }
  %w[PushCampaignsController InAppCampaignsController].each do |controller|
    register_mcp_subclass "Api::V1::Mcp::#{controller}#experiment", parent: "Api::V1::#{controller}#experiment",
                                                                    responses: { 200 => MCP_EXPERIMENT_OR_NONE }
  end
end
