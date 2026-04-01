class Api::V1::PurchasesController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project

  def purchases
    asc = ActiveModel::Type::Boolean.new.cast(asc_param)
    events = PurchaseQueryService.new(project: @project).search(
      page: page_param, sort_by: sort_by_param, asc: asc,
      start_date: start_date_param, end_date: end_date_param,
      term: term_param
    )

    render json: PaginatedResponse.new(events, data: PurchaseEventSerializer.serialize(events)), status: :ok
  end

  def revenue_metrics
    start_date = DateParamParser.call(start_date_param, default: 30.days.ago)
    end_date = DateParamParser.call(end_date_param, default: Time.now)

    page = [(page_param || 1).to_i, 1].max
    per_page = [(per_page_param || 20).to_i, 1].max
    sort_by = sort_by_param
    asc = ActiveModel::Type::Boolean.new.cast(asc_param)

    paginated = RevenueMetricsQuery.new(
      project_id: @project.id,
      start_date: start_date,
      end_date: end_date,
      product: term_param,
      platform: platforms_param,
      sort_by: sort_by,
      ascendent: asc
    ).with_arpu(page: page, per_page: per_page)

    render json: PaginatedResponse.new(paginated)
  end

end