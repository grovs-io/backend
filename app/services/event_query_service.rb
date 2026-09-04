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
    period = "day"
    query = EventMetricsQuery.new(project: nil)

    # CH only when link.active isn't filtered (not a CH events column). overview_ch
    # returns nil when CH is unavailable → fall back to the PG aggregation.
    metrics = nil
    if Clickhouse.analytics_rollups_read_enabled? && active.nil?
      metrics = query.overview_ch(
        @project_ids, parsed_start, parsed_end,
        sdk_generated: sdk_generated, ads_platform: ads_platform, campaign_ids: campaign_id,
        app_versions: app_versions, build_versions: build_versions, platforms: platforms
      )
    end

    if metrics.nil?
      events = Event.for_project(@project_ids)
                    .where(created_at: parsed_start.beginning_of_day..parsed_end.end_of_day)
      events = events.where(app_version: app_versions) if app_versions
      events = events.where(build: build_versions) if build_versions
      events = events.where(platform: platforms) if platforms
      metrics = query.overview(events, period, active, sdk_generated, ads_platform, campaign_id)
    end

    query.fill_gaps(metrics, parsed_start, parsed_end, period)
  end
end
