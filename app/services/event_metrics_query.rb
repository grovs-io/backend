class EventMetricsQuery
  # avg_engagement_time on the CH path = average engaged-session seconds for the link.
  ZERO_METRICS = { view: 0, open: 0, install: 0, reinstall: 0,
                   reactivation: 0, avg_engagement_time: 0.0 }.freeze
  METRIC_SORT_ID_CAP = Clickhouse::MAX_IN_LIST_IDS

  def initialize(project:)
    @project = project
  end

  def metrics_for_link_ids(link_ids, start_date, end_date)
    if Clickhouse.analytics_rollups_read_enabled?
      ch = ch_metrics_for_link_ids(link_ids, start_date, end_date)
      return ch unless ch.nil?
    end

    events = Event.for_project(@project.id)
                  .where(link_id: link_ids)
                  .where(created_at: start_date.beginning_of_day..end_date.end_of_day)

    aggregate(events)
  end

  def sorted_by_links(links:, page:, event_type:, asc:, start_date:, end_date:)
    if Clickhouse.analytics_rollups_read_enabled?
      ch = ch_sorted_by_links(links: links, page: page, event_type: event_type,
                              asc: asc, start_date: start_date, end_date: end_date)
      return ch unless ch.nil?
    end

    asc_value = asc ? "ASC" : "DESC"

    subquery = Event.for_project(@project.id)
                    .where(event: event_type)
                    .where(created_at: start_date.beginning_of_day..end_date.end_of_day)
                    .group(:link_id)
                    .select('link_id, COUNT(*) AS view_count')

    links_with_counts = links.joins("LEFT JOIN (#{subquery.to_sql}) AS event_counts ON links.id = event_counts.link_id")
                             .select(Arel.sql('links.*, COALESCE(event_counts.view_count, 0) AS view_count'))
                             .order(Arel.sql("view_count #{asc_value}"))

    links_with_counts = links_with_counts.page(page) if page

    all_events = Event.for_project(@project.id)
                      .where(created_at: start_date.beginning_of_day..end_date.end_of_day)

    metrics = aggregate(all_events)
    return_metrics = links_with_counts.map do |link|
      {
        link: link,
        metrics: metrics[link.id]
      }
    end

    if page
      return { result: return_metrics, page: page, total_pages: links_with_counts.total_pages }
    end

    return_metrics
  end

  def sorted_by_campaigns(campaigns:, page:, event_type:, asc:, start_date:, end_date:)
    asc_value = asc ? "ASC" : "DESC"

    subquery = Event.for_project(@project.id).joins(:link)
                    .where(event: event_type)
                    .where(created_at: start_date.beginning_of_day..end_date.end_of_day)
                    .where(links: { campaign_id: campaigns.map(&:id), sdk_generated: false })
                    .group('links.campaign_id')
                    .select('links.campaign_id, COUNT(*) AS view_count')

    campaigns_with_counts = campaigns.joins("LEFT JOIN (#{subquery.to_sql}) AS event_counts ON campaigns.id = event_counts.campaign_id")
                                     .select(Arel.sql('campaigns.*, COALESCE(event_counts.view_count, 0) AS view_count'))
                                     .order(Arel.sql("view_count #{asc_value}"))
                                     .page(page)

    all_events = Event.for_project(@project.id).joins(:link)
                      .where(created_at: start_date.beginning_of_day..end_date.end_of_day)
                      .where(links: { campaign_id: campaigns.map(&:id), sdk_generated: false })

    metrics = aggregate(all_events)

    campaign_link_map = Link.where(campaign_id: campaigns_with_counts.map(&:id))
                            .pluck(:campaign_id, :id)
                            .group_by(&:first)
                            .transform_values { |pairs| pairs.map(&:last) }

    return_metrics = campaigns_with_counts.map do |campaign|
      campaign_links = campaign_link_map[campaign.id] || []
      campaign_link_set = campaign_links.to_set
      campaign_metrics = metrics.select { |link_id, _| campaign_link_set.include?(link_id) }
      aggregated_metrics = campaign_metrics.values.each_with_object(Hash.new(0)) do |metric, agg|
        metric.each { |key, value| agg[key] += value }
      end
      {
        campaign: CampaignSerializer.serialize(campaign),
        metrics: aggregated_metrics,
        links: campaign_links
      }
    end

    { result: return_metrics }
  end

  def overview(events, period, active, sdk_generated, ads_platform, campaign_ids)
    results = events.left_joins(:link)

    results = results.where({ link: { campaign_id: campaign_ids } }) unless campaign_ids.nil?
    results = results.where(link: { active: active }) unless active.nil?
    results = results.where(link: { sdk_generated: sdk_generated }) unless sdk_generated.nil?
    results = results.where(link: { ads_platform: ads_platform }) unless ads_platform.nil?

    results = results
        .group("DATE_TRUNC('#{period}', events.created_at)", :event)
        .select("DATE_TRUNC('#{period}', events.created_at) as date", :event, 'COUNT(*) AS count', 'AVG(engagement_time) AS avg_engagement_time')
        # event: :asc matches CH's order so the order-dependent running avg agrees.
        .order(date: :asc, event: :asc)

    rows = results.map do |r|
      { date: r.date.to_s, event: r.event, count: r.count, avg_engagement_time: r.avg_engagement_time.to_f.round(2) }
    end
    accumulate_overview(rows)
  end

  # CH-served overview: same daily shape as #overview, from raw CH events. Only
  # valid when link.active is not being filtered (not a CH events column) — the
  # caller enforces that before routing here. period is always "day" upstream.
  # Returns nil when CH is unavailable so the caller falls back to the PG #overview.
  def overview_ch(project_ids, start_date, end_date, sdk_generated: nil, ads_platform: nil,
                  campaign_ids: nil, app_versions: nil, build_versions: nil, platforms: nil)
    ch_rows = ClickhouseReadService.event_overview_rows(
      project_ids, start_date: start_date, end_date: end_date,
      campaign_ids: campaign_ids, sdk_generated: sdk_generated, ads_platform: ads_platform,
      app_versions: app_versions, build_versions: build_versions, platforms: platforms
    )
    return nil if ch_rows.nil?

    rows = ch_rows.map do |r|
      { date: "#{r['date']} 00:00:00 UTC", event: r['event_type'],
        count: r['count'].to_i, avg_engagement_time: r['avg_engagement_time'].to_f.round(2) }
    end
    accumulate_overview(rows)
  end

  # Shared accumulation for PG and CH rows — identical output (incl. the legacy
  # order-dependent running avg_engagement_time). Rows: {date:, event:, count:, avg_engagement_time:}.
  def accumulate_overview(rows)
    data = {}
    rows.each do |r|
      date = r[:date]
      data[date] ||= { view: 0, open: 0, install: 0, reinstall: 0, reactivation: 0, avg_engagement_time: 0.0, user_referred: 0, app_open: 0 }
      data[date][r[:event].to_sym] = r[:count]
      data[date][:avg_engagement_time] = ((data[date][:avg_engagement_time] + r[:avg_engagement_time]) / 2.0).to_f.round(2)
    end
    data
  end

  def fill_gaps(result_hash, start_date, end_date, period)
    start_date = start_date.to_date if start_date.respond_to?(:to_date) && !start_date.is_a?(Date)
    end_date = end_date.to_date if end_date.respond_to?(:to_date) && !end_date.is_a?(Date)
    current_date = Date.today

    end_date = [end_date, current_date].min

    default_values = {
      "view" => 0,
      "open" => 0,
      "install" => 0,
      "reinstall" => 0,
      "reactivation" => 0,
      "avg_engagement_time" => 0.0,
      "app_open" => 0,
      "time_spent" => 0
    }

    if period == "day"
      all_dates = (start_date..end_date).map(&:to_s)
    else
      all_dates = []
      current_date = start_date
      while current_date <= end_date
        all_dates << current_date.strftime("%Y-%m-01")
        current_date = current_date.next_month
      end
    end

    all_dates.each do |date|
      timestamp = "#{date} 00:00:00 UTC"
      result_hash[timestamp] = default_values unless result_hash.key?(timestamp)
    end

    result_hash.sort.to_h
  end

  private

  # nil = CH disabled/failed → caller falls back to PG; {} = CH succeeded, no data.
  def ch_metrics_for_link_ids(link_ids, start_date, end_date)
    rows = ClickhouseReadService.link_event_type_counts(
      @project.id, link_ids: link_ids, start_date: start_date, end_date: end_date
    )
    return nil if rows.nil?

    data = rows.each_with_object({}) do |row, acc|
      metrics = (acc[row["link_id"].to_i] ||= ZERO_METRICS.dup)
      metrics[row["event_type"].to_sym] = row["cnt"].to_i
    end
    apply_session_averages(data, start_date, end_date)
  end

  # An all-empty result is indistinguishable from real zeroes, so it is counted, not silent.
  def apply_session_averages(data, start_date, end_date)
    return data if data.empty?

    averages = ClickhouseReadService.link_session_avg_seconds(
      @project.id, link_ids: data.keys, start_date: start_date, end_date: end_date
    )
    return data if averages.nil?

    Grovs::Metrics.increment("clickhouse.link_session_rollup.empty") if averages.empty?
    averages.each { |link_id, seconds| data[link_id][:avg_engagement_time] = seconds if data[link_id] }
    data
  end

  # No-activity links sort LAST in BOTH directions, as in LinkStatisticsQuery.
  def ch_sorted_by_links(links:, page:, event_type:, asc:, start_date:, end_date:)
    return nil unless Grovs::Events::ALL.include?(event_type.to_s)

    ids = links.limit(metric_sort_id_cap + 1).pluck(:id)
    return Clickhouse.id_cap_exceeded!(:link_event_sort, metric_sort_id_cap, fallback: :events) if ids.size > metric_sort_id_cap

    per = page ? Link.default_per_page : [ids.size, 1].max
    offset = page ? ([page.to_i, 1].max - 1) * per : 0

    result = ClickhouseReadService.link_event_sorted_page(
      @project.id, link_ids: ids, event_type: event_type.to_s, direction: asc ? "asc" : "desc",
      start_date: start_date, end_date: end_date, limit: per, offset: offset
    )
    return nil if result.nil?

    page_ids = result[:rows].map { |r| r["link_id"].to_i }
    # The contract requires view_count (a PG SELECT alias), so the CH path carries it too.
    counts = result[:rows].to_h { |r| [r["link_id"].to_i, r["metric"].to_i] }

    remaining = per - page_ids.size
    if remaining.positive? && ids.size > result[:active_count]
      active_ids = ClickhouseReadService.link_event_active_ids(
        @project.id, link_ids: ids, event_type: event_type.to_s,
        start_date: start_date, end_date: end_date
      )
      return nil if active_ids.nil?

      zero_offset = [offset - result[:active_count], 0].max
      page_ids += (ids - active_ids).sort[zero_offset, remaining] || []
    end

    # Same source as metrics_for_link_ids so both surfaces report identical shapes.
    metrics_by_id = ch_metrics_for_link_ids(page_ids, start_date, end_date)
    return nil if metrics_by_id.nil?

    links_by_id = links_with_view_count(page_ids, counts).index_by(&:id)
    return_metrics = page_ids.filter_map do |id|
      link = links_by_id[id]
      next unless link # PG-deleted but still in CH until the next rebuild

      { link: link, metrics: metrics_by_id[id] }
    end

    return return_metrics unless page

    { result: return_metrics, page: page, total_pages: (ids.size / per.to_f).ceil }
  end

  # Carries view_count as a real attribute, not a Hash — callers expect Link records.
  def links_with_view_count(page_ids, counts)
    return Link.none if page_ids.empty?

    cases = page_ids.map { |id| "WHEN #{id.to_i} THEN #{counts.fetch(id, 0).to_i}" }.join(" ")
    Link.select("links.*, CASE links.id #{cases} ELSE 0 END AS view_count").where(id: page_ids)
  end

  # Method (not constant ref) so tests can stub the cap.
  def metric_sort_id_cap = METRIC_SORT_ID_CAP

  def aggregate(events)
    results = events
        .group(:link_id, :event)
        .select(
            :link_id,
            :event,
            'SUM(engagement_time) AS total_engagement_time',
            'COUNT(DISTINCT device_id) AS device_count',
            'COUNT(*) AS count'
        )

    data = {}

    results.each do |result|
      link_id = result.link_id
      event_type = result.event
      count = result.count.to_i
      device_count = result.device_count.to_i
      total_engagement_time = result.total_engagement_time.to_f

      avg_engagement_time_per_device = device_count > 0 ? (total_engagement_time / device_count).round(2) : 0.0

      data[link_id] ||= { view: 0, open: 0, install: 0, reinstall: 0, reactivation: 0, avg_engagement_time: 0.0 }
      data[link_id][event_type.to_sym] = count
      if data[link_id][:avg_engagement_time].nil? || data[link_id][:avg_engagement_time] == 0
        data[link_id][:avg_engagement_time] = avg_engagement_time_per_device
      else
        data[link_id][:avg_engagement_time] = ((data[link_id][:avg_engagement_time] + avg_engagement_time_per_device) / 2.0).to_f.round(2)
      end
    end

    data
  end
end
