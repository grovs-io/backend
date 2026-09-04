class Api::V1::VisitorsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  include Api::V1::Concerns::AnalyticsRetentionGate
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project
  # The deprecated *_for_search_params actions are excluded: raw-events Arel, no ClickHouse branch.
  before_action :enforce_ch_retention_window!, only: %i[visitors aggregated_visitors]

  def aggregated_visitors
    result = VisitorReferralStatisticsQuery.new(params: params, project: @project).call

    render json: result, status: :ok
  end

  def visitors
    result = VisitorStatisticsQuery.new(params: params, project: @project).call

    render json: result, status: :ok
  end

  # DEPRECATED / MARKED FOR DELETION (2026-07-15): the two "OLD API Calls" actions below
  # (visitors/aggregated_metrics + visitors/metrics) aggregate per-visitor event CASE-sums over
  # the RAW events table with NO date bound — catastrophic at scale. FE no longer calls these
  # paths. Remove both actions + their routes after confirming zero server traffic.
  # OLD API Calls
  def aggregated_visitor_metrics_for_search_params
    Grovs::Metrics.increment("deprecated_endpoint.hit", tags: { endpoint: "visitors/aggregated_metrics" })
    start_date = DateParamParser.call(start_date_param, default: 30.days.ago)
    end_date = DateParamParser.call(end_date_param, default: Time.now)

    metrics = VisitorReferralStatisticsQuery.paginated_aggregated_events(
      page: page_param, event_type: sort_by_param, asc: asc_param, project: @project,
      start_date: start_date, end_date: end_date, term: term_param, per_page: per_page_param
    )

    render json: metrics, status: :ok
  end

  def visitor_metrics_for_search_params
    Grovs::Metrics.increment("deprecated_endpoint.hit", tags: { endpoint: "visitors/metrics" })
    start_date = DateParamParser.call(start_date_param, default: 30.days.ago)
    end_date = DateParamParser.call(end_date_param, default: Time.now)

    metrics = VisitorStatisticsQuery.paginated_own_events(page: page_param, event_type: sort_by_param, asc: asc_param, project: @project,
start_date: start_date, end_date: end_date, term: term_param, visitor_id: visitor_id_optional_param, per_page: per_page_param)

    render json: metrics, status: :ok

  end

  def visitor_details
    # Non-numeric ids integer-cast (uuid "550e8400-..." -> 550) and resolve the wrong visitor.
    unless visitor_id_param.to_s.match?(/\A\d+\z/)
      return render json: { error: "visitor_id must be numeric" }, status: :bad_request
    end

    visitor = find_authorized_resource(Visitor, visitor_id_param)
    return unless visitor

    number_of_links = Link.where(visitor_id: visitor.id, domain_id: @project.domain.id).count

    # total_* covers this range, not the visitor's whole life, once retention clamps it.
    metrics_since = retention_floor(visitor.created_at.to_date)
    params = {start_date: metrics_since, end_date: Date.tomorrow, visitor_id: visitor.id}
    own_metrics = VisitorStatisticsQuery.new(params: params, project: @project).call
    metrics = own_metrics[:visitors]&.first || zero_filled_stats(visitor, "total_", with_platform: true)

    aggregated_values = VisitorReferralStatisticsQuery.new(params: params, project: @project).call
    aggregated_metrics = aggregated_values[:visitors]&.first || zero_filled_stats(visitor, "invited_")

    render json: {
      visitor: VisitorSerializer.serialize(visitor), metrics: metrics,
      aggregated_metrics: aggregated_metrics, number_of_generated_links: number_of_links,
      metrics_since: metrics_since
    }, status: :ok
  end

  private

  # Same shape as the populated query row, zeroed — visitors with no daily stats never get metrics: null.
  def zero_filled_stats(visitor, prefix, with_platform: false)
    stats = VisitorSerializer.serialize(visitor, slim: true)
    stats["platform"] = visitor.device&.platform if with_platform
    VisitorDailyStatistic::METRIC_COLUMNS.each { |col| stats["#{prefix}#{col}"] = 0 }
    stats
  end

  # Params

  def visitor_id_param
    params.require(:visitor_id)
  end

  def visitor_id_optional_param
    params.permit(:visitor_id)[:visitor_id]
  end

end