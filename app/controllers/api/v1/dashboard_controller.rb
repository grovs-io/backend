class Api::V1::DashboardController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project

  def metrics_overview
    start_date = DateParamParser.call(start_date_param, default: 30.days.ago)
    end_date = DateParamParser.call(end_date_param, default: Time.now)

    metrics = DashboardMetrics.call(
      project_id: @project.id,
      platform: platforms_param,
      start_time: start_date,
      end_time: end_date,
    )

    render json: {metrics: metrics}, status: :ok
  end

  def links_views
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