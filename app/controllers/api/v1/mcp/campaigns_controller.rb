class Api::V1::Mcp::CampaignsController < Api::V1::Mcp::BaseController
  before_action :load_mcp_project

  # POST /api/v1/mcp/campaigns
  def create
    params.require(:name)

    campaign = CampaignManagementService.new(project: @project).create(name: params[:name])
    render json: { campaign: CampaignSerializer.serialize(campaign) }, status: :created
  rescue ArgumentError => e
    render json: { error: e.message }, status: :bad_request
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/mcp/campaigns/search
  def index
    result = CampaignStatisticsQuery.new(
      params: params,
      project: @project
    ).call

    campaigns = result.map { |c| CampaignSerializer.serialize(c) }

    render json: {
      campaigns: campaigns,
      meta: {
        page: result.current_page,
        per_page: result.limit_value,
        total_pages: result.total_pages,
        total_entries: result.total_count
      }
    }, status: :ok
  end

  # DELETE /api/v1/mcp/campaigns/:campaign_id
  def archive
    campaign = Campaign.find_by(id: params[:campaign_id])
    unless campaign && campaign.project_id == @project.id
      render json: { error: "Campaign not found" }, status: :not_found
      return
    end

    archived = CampaignManagementService.new(project: @project).archive(campaign: campaign)
    render json: { campaign: CampaignSerializer.serialize(archived) }, status: :ok
  rescue ArgumentError => e
    render json: { error: e.message }, status: :bad_request
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
