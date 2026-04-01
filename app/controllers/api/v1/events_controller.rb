class Api::V1::EventsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project, except: [:events_for_payment_screen]
  before_action :load_instance, only: [:events_for_payment_screen]

  def events_for_search_params

    links = links_for_search_params
    unless links
      return
    end

    start_date = DateParamParser.call(start_date_param, default: Date.today - 30)
    end_date = DateParamParser.call(end_date_param, default: Date.today)

    link_ids = links.map(&:id)
    metrics = EventMetricsQuery.new(project: @project).metrics_for_link_ids(link_ids, start_date, end_date)

    render json: {metrics: metrics}, status: :ok
  end

  def events_sorted_by_param
    links = links_for_search_params_no_pagination_and_order
    start_date = DateParamParser.call(start_date_param, default: Date.today - 30)
    end_date = DateParamParser.call(end_date_param, default: Date.today)

    metrics = EventMetricsQuery.new(project: @project).sorted_by_links(
      links: links, page: page_param, event_type: event_type_param,
      asc: asc_param, start_date: start_date, end_date: end_date
    )

    render json: metrics, status: :ok
  end

  def events_for_overview
    events_for_overview_for_project_ids([@project.id], sdk_generated_param)
  end


  def events_for_payment_screen
    if @instance.test.nil? || @instance.production.nil?
      render json: {error: "Instance projects not configured"}, status: :not_found
      return
    end

    project_ids = [@instance.test.id, @instance.production.id]

    start_date = DateParamParser.call(start_date_param, default: 30.days.ago.to_date)
    end_date = DateParamParser.call(end_date_param, default: Date.today)

    metrics = VisitorsMetricsQuery.new(
        project_ids: project_ids,
        start_date: start_date,
        end_date: end_date
    ).call

    render json: metrics, status: :ok
  end


  def metrics_values
    events = Event.for_project(@project.id)

    platforms = events.distinct.pluck(:platform).compact
    app_versions = events.distinct.pluck(:app_version).compact
    builds = events.distinct.pluck(:build).compact

    return_value = {
        platforms: platforms,
        app_versions: app_versions,
        builds: builds
      }

    render json: {metrics_values: return_value}, status: :ok
  end

  private

  def events_for_overview_for_project_ids(project_ids, sdk_generated)
    metrics = EventQueryService.new(project_ids: project_ids).overview_metrics(
      start_date: start_date_param, end_date: end_date_param,
      active: active_param, sdk_generated: sdk_generated,
      ads_platform: ads_platform_param, campaign_id: campaign_id_param,
      app_versions: app_versions_param, build_versions: build_versions_param,
      platforms: platforms_param
    )

    render json: metrics, status: :ok
  end

  # Params

  def sdk_generated_param
    params.permit(:sdk_generated)[:sdk_generated]
  end

  def page_param
    params.require(:page)
  end

  def event_type_param
    params.require(:event_type)
  end

  def app_versions_param
    params.permit(app_versions: [])[:app_versions]
  end

  def build_versions_param
    params.permit(build_versions: [])[:build_versions]
  end

  def platforms_param
    params.permit(platforms: [])[:platforms]
  end

  def active_param
    params.permit(:active)[:active]
  end

end
