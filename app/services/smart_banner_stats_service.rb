module SmartBannerStatsService
  WINDOW_DAYS = 30

  module_function

  def for_banners(project, banners)
    empty = banners.to_h { |banner| [banner.id, SmartBannerSerializer::EMPTY_STATS] }
    return empty if banners.empty? || !Clickhouse.read_enabled?

    since = WINDOW_DAYS.days.ago.to_date.iso8601
    events = banner_event_counts(project.id, banners.map(&:id), since)
    link_totals = link_event_counts(project.id, banners.map(&:id), since)

    banners.to_h { |banner| [banner.id, stats_for(events[banner.id], link_totals["smart_banner:#{banner.id}"])] }
  rescue StandardError => e
    Rails.logger.error("smart_banners.stats_failed project=#{project.id} #{e.class}: #{e.message}")
    Grovs::Metrics.increment("smart_banners.stats_failed")
    empty
  end

  def banner_event_counts(project_id, banner_ids, since)
    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT CAST(properties.smart_banner_id AS String) AS banner_id,
               uniqExactIf(event_id, event_name = 'smart_banner_view') AS views,
               uniqExactIf(event_id, event_name = 'smart_banner_click') AS clicks,
               uniqExactIf(event_id, event_name = 'smart_banner_dismiss') AS dismisses
        FROM events
        WHERE project_id = {project_id:UInt64}
          AND event_type = 'custom'
          AND event_name IN ('smart_banner_view', 'smart_banner_click', 'smart_banner_dismiss')
          AND toDate(created_at) >= {since:Date}
          AND banner_id IN {banner_ids:Array(String)}
        GROUP BY banner_id
      SQL
      placeholders: { project_id: Integer(project_id), since: since, banner_ids: banner_ids.map(&:to_s) }
    )
    Clickhouse.with { |conn| conn.select_all(query) }.index_by { |row| row["banner_id"].to_i }
  end

  # Banner links carry a smart_banner:<id> tag, frozen onto each event's link_tags at ingest.
  def link_event_counts(project_id, banner_ids, since)
    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT tag,
               uniqExactIf(event_id, event_type = 'open') AS opens,
               uniqExactIf(event_id, event_type IN ('install', 'reinstall')) AS installs
        FROM events
        ARRAY JOIN link_tags AS tag
        WHERE project_id = {project_id:UInt64}
          AND event_type IN ('open', 'install', 'reinstall')
          AND toDate(created_at) >= {since:Date}
          AND has(link_tags, 'smart_banner')
          AND tag IN {tags:Array(String)}
        GROUP BY tag
      SQL
      placeholders: { project_id: Integer(project_id), since: since,
                      tags: banner_ids.map { |id| "smart_banner:#{id}" } }
    )
    Clickhouse.with { |conn| conn.select_all(query) }.index_by { |row| row["tag"] }
  end

  def stats_for(event_row, link_total)
    views = event_row ? event_row["views"].to_i : 0
    clicks = event_row ? event_row["clicks"].to_i : 0
    {
      "views" => views,
      "clicks" => clicks,
      "dismisses" => event_row ? event_row["dismisses"].to_i : 0,
      "ctr" => views.zero? ? 0.0 : (clicks.to_f / views).round(4),
      "opens" => link_total ? link_total["opens"].to_i : 0,
      "installs" => link_total ? link_total["installs"].to_i : 0
    }
  end
end
