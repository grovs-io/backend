class Api::V1::CampaignsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  include Api::V1::Concerns::AnalyticsRetentionGate
  # wrap_parameters nests JSON bodies under :campaign, breaking the strict request contract.
  wrap_parameters false
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project
  # current_project_campaigns is excluded: sorted_by_campaigns is PG-only, no ClickHouse branch.
  before_action :enforce_ch_retention_window!, only: %i[current_project_campaigns_v2 metrics_for_overview]

  def current_project_campaigns_v2
    campaigns = CampaignStatisticsQuery.new(project: @project, params: params).call
    serialized = CampaignSerializer.serialize(campaigns)
    render json: PaginatedResponse.new(campaigns, data: serialized), status: :ok
  end

  # DEPRECATED / MARKED FOR DELETION (2026-07-15): superseded by current_project_campaigns_v2
  # (campaigns/search_v2). Backed by EventMetricsQuery#sorted_by_campaigns — 2x raw-events scans
  # + COUNT(DISTINCT device_id). FE no longer calls campaigns/search. Remove after zero-traffic check.
  def current_project_campaigns
    Grovs::Metrics.increment("deprecated_endpoint.hit", tags: { endpoint: "campaigns/search" })
    campaigns = campaigns_for_search_params
    return unless campaigns

    start_date = DateParamParser.call(start_date_param, default: Date.today - 30)
    end_date = DateParamParser.call(end_date_param, default: Date.today)

    campaigns_with_events = EventMetricsQuery.new(project: @project).sorted_by_campaigns(campaigns: campaigns, page: page_param, event_type: sort_by_param,
asc: asc_param, start_date: start_date, end_date: end_date)

    render json: PaginatedResponse.new(campaigns, data: campaigns_with_events), status: :ok
  end

  def create
    campaign = campaign_service(@project).create(name: campaign_params[:name])
    render json: { campaign: CampaignSerializer.serialize(campaign) }, status: :ok
  rescue ArgumentError => e
    render json: { error: e.message }, status: :not_found
  end

  def update
    campaign = campaign_for_param
    return unless campaign

    updated = campaign_service(@project).update(campaign: campaign, attrs: campaign_params)
    render json: { campaign: CampaignSerializer.serialize(updated) }, status: :ok
  end

  def archive
    campaign = campaign_for_param
    return unless campaign

    archived = campaign_service(@project).archive(campaign: campaign)
    render json: { campaign: CampaignSerializer.serialize(archived) }, status: :ok
  end

  # DEPRECATED (2026-07-25): remove with its route after zero external/MCP traffic check.
  def metrics_for_overview
    campaigns = campaigns_for_search_params

    start_date = DateParamParser.call(start_date_param, default: Date.today - 30)
    end_date = DateParamParser.call(end_date_param, default: Date.today)

    period = "day"
    campaign_ids = campaigns.ids
    query = EventMetricsQuery.new(project: @project)

    # active is never filtered here, so CH is eligible when the flag is on;
    # overview_ch returns nil when CH is unavailable → fall back to PG.
    metrics = nil
    if Clickhouse.analytics_rollups_read_enabled?
      metrics = query.overview_ch([@project.id], start_date, end_date, sdk_generated: false, campaign_ids: campaign_ids)
    end
    if metrics.nil?
      events = Event.for_project(@project.id)
                    .where(created_at: start_date.beginning_of_day..end_date.end_of_day)
      metrics = query.overview(events, period, nil, false, nil, campaign_ids)
    end
    metrics = query.fill_gaps(metrics, start_date, end_date, period)

    render json: metrics, status: :ok
  end

  private

  def campaign_service(project)
    CampaignManagementService.new(project: project)
  end

  def campaigns_for_search_params
    CampaignQueryService.new(project: @project).search(
      archived: archived_param,
      page: page_param, per_page: per_page_param,
      sort_by: sort_by_param, asc: asc_param,
      start_date: start_date_param, end_date: end_date_param,
      term: term_param
    )
  end

  def campaign_for_param
    find_authorized_resource(Campaign, campaign_id_param)
  end

  # Params

  def campaign_params
    params.permit(:name)
  end

  def campaign_id_param
    params.require(:campaign_id)
  end

  def archived_param
    params.require(:archived)
  end
end
