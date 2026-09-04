class Api::V1::DashboardController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  include Api::V1::Concerns::AnalyticsRetentionGate
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project
  # links_views is excluded: PG-only report, never reads ClickHouse.
  before_action :enforce_ch_retention_window!, only: %i[metrics_overview best_performing_links]

  # DEPRECATED: delete only after the zero-traffic check; DashboardMetrics itself stays (MCP).
  def metrics_overview
    start_date = DateParamParser.call(start_date_param, default: 30.days.ago)
    end_date = DateParamParser.call(end_date_param, default: Time.now)

    metrics = DashboardMetrics.call(
      project_id: @project.id,
      platform: platforms_param,
      start_time: start_date,
      end_time: end_date,
      cutoff: retention_cutoff
    )

    render json: {metrics: metrics}, status: :ok
  end

  # DEPRECATED (2026-07-25): remove with LinksViewsReportDashboard after zero-traffic check.
  def links_views
    Grovs::Metrics.increment("deprecated_endpoint.hit", tags: { endpoint: "dashboard/links_views" })
    # 410, not 503: its only source is daily_project_metrics, which never fills again once frozen.
    unless Grovs.pg_shadow_writes?
      return render json: { error: 'This report was retired with the Postgres stat tables',
                            error_code: 'endpoint_retired' }, status: :gone
    end

    start_date = DateParamParser.call(start_date_param, default: 30.days.ago)
    end_date = DateParamParser.call(end_date_param, default: Time.now)

    metrics = LinksViewsReportDashboard.new(
      project_id: @project.id,
      platform: platforms_param,
      start_date: start_date,
      end_date: end_date
    ).call

    render json: {metrics: metrics}, status: :ok
  end

  def best_performing_links
    start_date = DateParamParser.call(start_date_param, default: 30.days.ago)
    end_date = DateParamParser.call(end_date_param, default: Time.now)

    links = TopLinksAnalytics.new(
      project_id: @project.id,
      platform: platforms_param,
      start_time: start_date,
      end_time: end_date,
      limit: 10
    ).call

    render json: {links: links}, status: :ok
  end

end
