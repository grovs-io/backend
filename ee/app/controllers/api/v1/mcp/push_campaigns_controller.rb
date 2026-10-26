class Api::V1::Mcp::PushCampaignsController < Api::V1::PushCampaignsController
  include McpProjectController

  rescue_from Experiments::Report::NotApplicable do
    render json: { experiment: nil }, status: :ok
  end

  private

  # Slim drops the frozen recipient list (up to 10k identifiers) but keeps the report.
  def render_one(status) = render(json: { push_campaign: PushCampaignSerializer.serialize(@campaign, slim: true) }, status: status)
end
