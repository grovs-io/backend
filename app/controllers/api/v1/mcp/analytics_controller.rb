class Api::V1::Mcp::AnalyticsController < Api::V1::Mcp::BaseController
  before_action :load_mcp_project
  before_action :parse_date_range

  # POST /api/v1/mcp/analytics/link
  def link_stats
    domain = @project.domain
    unless domain
      render json: { error: "Project has no domain configured" }, status: :not_found
      return
    end

    link = domain.links.find_by(path: params[:path])
    unless link
      render json: { error: "Link not found" }, status: :not_found
      return
    end

    metrics = EventMetricsQuery.new(
      project: @project
    ).metrics_for_link_ids([link.id], @start_date, @end_date)

    render json: { link_path: link.path, metrics: metrics }, status: :ok
  end

  # POST /api/v1/mcp/analytics/overview
  def project_metrics
    metrics = DashboardMetrics.call(
      project_id: @project.id,
      platform: params[:platform],
      start_time: @start_date,
      end_time: @end_date
    )

    render json: { metrics: metrics }, status: :ok
  end

  # POST /api/v1/mcp/analytics/top_links
  def top_links
    links = TopLinksAnalytics.new(
      project_id: @project.id,
      platform: params[:platform],
      start_time: @start_date,
      end_time: @end_date,
      limit: params.fetch(:limit, 10).to_i
    ).call

    render json: { links: links }, status: :ok
  end
end
