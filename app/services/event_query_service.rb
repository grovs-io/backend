class EventQueryService
  def initialize(project_ids:)
    @project_ids = project_ids
  end

  # Returns filled metrics hash for overview charts.
  def overview_metrics(start_date: nil, end_date: nil, active: nil, sdk_generated: nil,
                       ads_platform: nil, campaign_id: nil,
                       app_versions: nil, build_versions: nil, platforms: nil)
    parsed_start = DateParamParser.call(start_date, default: Date.today - 30)
    parsed_end = DateParamParser.call(end_date, default: Date.today)

    events = Event.for_project(@project_ids)
                  .where(created_at: parsed_start.beginning_of_day..parsed_end.end_of_day)

    events = events.where(app_version: app_versions) if app_versions
    events = events.where(build: build_versions) if build_versions
    events = events.where(platform: platforms) if platforms

    period = "day"
    query = EventMetricsQuery.new(project: nil)
    metrics = query.overview(events, period, active, sdk_generated, ads_platform, campaign_id)
    query.fill_gaps(metrics, parsed_start, parsed_end, period)
  end
end
