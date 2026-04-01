class Api::V1::VisitorsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project

  def aggregated_visitors
    result = VisitorReferralStatisticsQuery.new(params: params, project: @project).call

    render json: result, status: :ok
  end

  def visitors
    result = VisitorStatisticsQuery.new(params: params, project: @project).call

    render json: result, status: :ok
  end

  # OLD API Calls
  def aggregated_visitor_metrics_for_search_params
    start_date = DateParamParser.call(start_date_param, default: 30.days.ago)
    end_date = DateParamParser.call(end_date_param, default: Time.now)

    metrics = VisitorReferralStatisticsQuery.paginated_aggregated_events(
      page: page_param, event_type: sort_by_param, asc: asc_param, project: @project,
      start_date: start_date, end_date: end_date, term: term_param, per_page: per_page_param
    )

    render json: metrics, status: :ok
  end

  def visitor_metrics_for_search_params
    start_date = DateParamParser.call(start_date_param, default: 30.days.ago)
    end_date = DateParamParser.call(end_date_param, default: Time.now)

    metrics = VisitorStatisticsQuery.paginated_own_events(page: page_param, event_type: sort_by_param, asc: asc_param, project: @project,
start_date: start_date, end_date: end_date, term: term_param, visitor_id: visitor_id_optional_param, per_page: per_page_param)

    render json: metrics, status: :ok

  end

  def visitor_details
    visitor = find_authorized_resource(Visitor, visitor_id_param)
    return unless visitor

    number_of_links = Link.where(visitor_id: visitor.id, domain_id: @project.domain.id).count

    params = {start_date: visitor.created_at.to_date, end_date: Date.tomorrow, visitor_id: visitor.id}
    own_metrics = VisitorStatisticsQuery.new(params: params, project: @project).call
    metrics = own_metrics[:visitors]&.first

    aggregated_values = VisitorReferralStatisticsQuery.new(params: params, project: @project).call
    aggregated_metrics = aggregated_values[:visitors]&.first

    render json: {
      visitor: VisitorSerializer.serialize(visitor), metrics: metrics,
      aggregated_metrics: aggregated_metrics, number_of_generated_links: number_of_links
    }, status: :ok
  end

  private

  # Params

  def visitor_id_param
    params.require(:visitor_id)
  end

  def visitor_id_optional_param
    params.permit(:visitor_id)[:visitor_id]
  end

end