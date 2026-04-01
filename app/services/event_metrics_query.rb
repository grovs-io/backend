class EventMetricsQuery
  def initialize(project:)
    @project = project
  end

  def metrics_for_link_ids(link_ids, start_date, end_date)
    events = Event.for_project(@project.id)
                  .where(link_id: link_ids)
                  .where(created_at: start_date.beginning_of_day..end_date.end_of_day)

    aggregate(events)
  end

  def sorted_by_links(links:, page:, event_type:, asc:, start_date:, end_date:)
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
        .order(date: :asc)

    data = {}

    results.each do |result|
      date = result.date.to_s
      event_type = result.event
      count = result.count
      avg_engagement_time = result.avg_engagement_time.to_f.round(2)

      data[date] ||= { view: 0, open: 0, install: 0, reinstall: 0, reactivation: 0, avg_engagement_time: 0.0, user_referred: 0, app_open: 0 }
      data[date][event_type.to_sym] = count
      data[date][:avg_engagement_time] = ((data[date][:avg_engagement_time] + avg_engagement_time) / 2.0).to_f.round(2)
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
