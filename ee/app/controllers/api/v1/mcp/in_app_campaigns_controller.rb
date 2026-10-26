class Api::V1::Mcp::InAppCampaignsController < Api::V1::InAppCampaignsController
  include McpProjectController

  rescue_from Experiments::Report::NotApplicable do
    render json: { experiment: nil }, status: :ok
  end
end
