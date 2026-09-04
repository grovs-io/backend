# frozen_string_literal: true

# rubocop:disable Metrics/ModuleLength -- catalog of independent CH read queries
module ClickhouseReadService
  # Bound billing reads the same way Analytics::QueryHelpers bounds interactive reads.
  # A wide range over a large project (uniqExactMerge across months) can otherwise hang
  # or OOM CH; with the cap it raises, the method returns nil, and the caller falls back
  # to PG billing instead of hanging.
  # Bare pairs (no SETTINGS keyword) so they can merge into a query's own SETTINGS.
  QUERY_GUARD_PAIRS = "max_execution_time = #{Analytics::Config::QUERY_MAX_EXECUTION_SEC}, " \
                      "max_memory_usage = #{Analytics::Config::QUERY_MAX_MEMORY_BYTES}"
  BILLING_QUERY_GUARD = "SETTINGS #{QUERY_GUARD_PAIRS}"
  # Spills instead of raising: per-visitor first-seen groups a tenant's whole history.
  EXTERNAL_GROUP_BY_BYTES = Analytics::Config::QUERY_MAX_MEMORY_BYTES / 4
  FIRST_SEEN_QUERY_GUARD =
    "SETTINGS #{QUERY_GUARD_PAIRS}, max_bytes_before_external_group_by = #{EXTERNAL_GROUP_BY_BYTES}"

  # CH rollups store RAW device platform; PG stores platform_for_metrics (else -> web).
  def self.normalized_platform_sql(prefix = '')
    "if(#{prefix}platform IN ('ios', 'android'), #{prefix}platform, 'web')"
  end
  NORMALIZED_PLATFORM_SQL = normalized_platform_sql

  # Known platforms only: 'mac' must find the web bucket, but a typo must still match nothing.
  def self.normalize_platform_value(value)
    v = value.to_s
    return v unless Grovs::Platforms::ALL.include?(v)

    %w[ios android].include?(v) ? v : "web"
  end

  # Project-level event counts by date, event_type, platform.
  def self.project_daily_stats(project_id, start_date:, end_date:)
    return [] unless Clickhouse.read_enabled?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          event_date,
          event_type,
          platform,
          sum(cnt)                   AS cnt,
          sum(total_engagement_time) AS total_engagement_time,
          uniqMerge(visitors_state)  AS unique_visitors,
          uniqMerge(devices_state)   AS unique_devices
        FROM project_daily
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
        GROUP BY event_date, event_type, platform
        ORDER BY event_date, event_type, platform
      SQL
      placeholders: {
        project_id: Integer(project_id),
        start_date: format_date(start_date),
        end_date: format_date(end_date)
      }
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:project_daily_stats, e)
    []
  end

  # Phase 6 — project daily metric TOTALS for the dashboard, from the exact
  # rebuilt rollup (project_metrics_daily). Sums the 5 directly-countable columns
  # over the range. Returns { views:, opens:, installs:, reinstalls:, app_opens: }
  # or nil when CH reads are unavailable/failed so DashboardMetrics falls back to
  # Postgres instead of serving an accidental zero. `platform` may be a single
  # value or an Array (the dashboard passes either).
  def self.project_metrics_daily_totals(project_id, start_date:, end_date:, platform: nil)
    return nil unless Clickhouse.read_enabled?

    platforms = Array(platform).map(&:to_s).reject(&:empty?)
    platform_filter = platforms.empty? ? "" : "AND #{NORMALIZED_PLATFORM_SQL} IN {platforms:Array(String)}"
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date)
    }
    placeholders[:platforms] = platforms unless platforms.empty?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          sum(views)      AS views,
          sum(opens)      AS opens,
          sum(installs)   AS installs,
          sum(reinstalls) AS reinstalls,
          sum(app_opens)  AS app_opens
        FROM project_metrics_daily
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
          #{platform_filter}
      SQL
      placeholders: placeholders
    )
    row = Clickhouse.with { |conn| conn.select_all(query).first }
    {
      views: row ? row["views"].to_i : 0,
      opens: row ? row["opens"].to_i : 0,
      installs: row ? row["installs"].to_i : 0,
      reinstalls: row ? row["reinstalls"].to_i : 0,
      app_opens: row ? row["app_opens"].to_i : 0
    }
  rescue StandardError => e
    log_query_failure(:project_metrics_daily_totals, e)
    nil
  end

  # Link-level stats: counts by link, date, event_type, platform.
  def self.link_daily_stats(project_id, link_id:, start_date:, end_date:)
    return [] unless Clickhouse.read_enabled?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          event_date,
          event_type,
          platform,
          sum(cnt)                   AS cnt,
          sum(total_engagement_time) AS total_engagement_time
        FROM link_daily
        WHERE project_id = {project_id:UInt64}
          AND link_id = {link_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
        GROUP BY event_date, event_type, platform
        ORDER BY event_date, event_type, platform
      SQL
      placeholders: {
        project_id: Integer(project_id),
        link_id: Integer(link_id),
        start_date: format_date(start_date),
        end_date: format_date(end_date)
      }
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:link_daily_stats, e)
    []
  end

  # Top links by total event count within a date range.
  def self.top_links(project_id, start_date:, end_date:, event_type: nil, limit: 10)
    return [] unless Clickhouse.read_enabled?

    if event_type
      query = ClickHouse::Client::Query.new(
        raw_query: <<~SQL,
          SELECT link_id, sum(cnt) AS cnt
          FROM link_daily
          WHERE project_id = {project_id:UInt64}
            AND event_date >= {start_date:Date}
            AND event_date <= {end_date:Date}
            AND event_type = {event_type:String}
          GROUP BY link_id
          ORDER BY cnt DESC
          LIMIT {limit:UInt32}
        SQL
        placeholders: {
          project_id: Integer(project_id),
          start_date: format_date(start_date),
          end_date: format_date(end_date),
          event_type: event_type.to_s,
          limit: Integer(limit)
        }
      )
    else
      query = ClickHouse::Client::Query.new(
        raw_query: <<~SQL,
          SELECT link_id, sum(cnt) AS cnt
          FROM link_daily
          WHERE project_id = {project_id:UInt64}
            AND event_date >= {start_date:Date}
            AND event_date <= {end_date:Date}
          GROUP BY link_id
          ORDER BY cnt DESC
          LIMIT {limit:UInt32}
        SQL
        placeholders: {
          project_id: Integer(project_id),
          start_date: format_date(start_date),
          end_date: format_date(end_date),
          limit: Integer(limit)
        }
      )
    end
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:top_links, e)
    []
  end

  # Per-link pivoted metrics ranked by installs, over the parity-blessed
  # link_metrics_daily rollup. link_ids scopes the set (callers pass the bounded
  # non-SDK link ids so sdk_generated:false parity is preserved without a rollup
  # column). Integer-coerced ids are interpolated (no Array placeholder support).
  # Returns nil when CH is unavailable (disabled/errored) so callers fall back to PG.
  def self.top_link_metrics(project_id, link_ids:, start_date:, end_date:, platform: nil, limit: 10)
    return nil unless Clickhouse.read_enabled?

    ids = Array(link_ids).map { |i| Integer(i) }
    return [] if ids.empty?

    platform_clause = platform.present? ? "AND #{NORMALIZED_PLATFORM_SQL} = {platform:String}" : ''
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date),
      limit: Integer(limit)
    }
    placeholders[:platform] = platform.to_s if platform.present?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          link_id,
          sum(views)         AS views,
          sum(opens)         AS opens,
          sum(installs)      AS installs,
          sum(reinstalls)    AS reinstalls,
          sum(reactivations) AS reactivations,
          sum(time_spent)    AS time_spent
        FROM link_metrics_daily
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
          AND link_id IN (#{ids.join(',')})
          #{platform_clause}
        GROUP BY link_id
        ORDER BY installs DESC, link_id ASC
        LIMIT {limit:UInt32}
      SQL
      placeholders: placeholders
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:top_link_metrics, e)
    nil
  end

  # Per-link summed metrics for a specific set of link ids (no ranking), over the
  # parity-blessed link_metrics_daily rollup. Returns rows keyed by link_id; used to
  # attach metrics to a page of links already selected/sorted in PG. Revenue is NOT
  # here (uncovered by the rollup — purchase pipeline); the caller sums it from PG.
  def self.link_metrics_by_id(project_id, link_ids:, start_date:, end_date:, platform: nil)
    return nil unless Clickhouse.read_enabled?

    ids = Array(link_ids).map { |i| Integer(i) }
    return [] if ids.empty?

    platform_clause = platform.present? ? "AND #{NORMALIZED_PLATFORM_SQL} = {platform:String}" : ''
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date)
    }
    placeholders[:platform] = platform.to_s if platform.present?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          link_id,
          sum(views)         AS views,
          sum(opens)         AS opens,
          sum(installs)      AS installs,
          sum(reinstalls)    AS reinstalls,
          sum(time_spent)    AS time_spent,
          sum(reactivations) AS reactivations,
          sum(app_opens)     AS app_opens,
          sum(user_referred) AS user_referred
        FROM link_metrics_daily
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
          AND link_id IN (#{ids.join(',')})
          #{platform_clause}
        GROUP BY link_id
      SQL
      placeholders: placeholders
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:link_metrics_by_id, e)
    nil
  end

  # Unlike link_metrics_daily this carries custom/screen_view, which have no counter column.
  def self.link_event_type_counts(project_id, link_ids:, start_date:, end_date:)
    return nil unless Clickhouse.read_enabled?

    ids = Array(link_ids).map { |i| Integer(i) }
    return [] if ids.empty?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT link_id, event_type, sum(cnt) AS cnt
        FROM link_daily
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
          AND link_id IN (#{ids.join(',')})
        GROUP BY link_id, event_type
      SQL
      placeholders: {
        project_id: Integer(project_id),
        start_date: format_date(start_date),
        end_date: format_date(end_date)
      }
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:link_event_type_counts, e)
    nil
  end

  # Link ids with a NON-ZERO count of this event type — the complement is the zero tail.
  def self.link_event_active_ids(project_id, link_ids:, event_type:, start_date:, end_date:)
    return nil unless Clickhouse.read_enabled?

    ids = Array(link_ids).map { |i| Integer(i) }
    return [] if ids.empty?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT link_id
        FROM link_daily
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
          AND link_id IN (#{ids.join(',')})
        GROUP BY link_id
        HAVING sumIf(cnt, event_type = {event_type:String}) > 0
      SQL
      placeholders: {
        project_id: Integer(project_id),
        event_type: event_type.to_s,
        start_date: format_date(start_date),
        end_date: format_date(end_date)
      }
    )
    Clickhouse.with { |conn| conn.select_all(query) }.map { |r| r["link_id"].to_i }
  rescue StandardError => e
    log_query_failure(:link_event_active_ids, e)
    nil
  end

  # Ranked from the same table link_event_type_counts reads, so rank and value agree.
  def self.link_event_sorted_page(project_id, link_ids:, event_type:, direction:,
                                  start_date:, end_date:, limit:, offset:)
    return nil unless Clickhouse.read_enabled?

    ids = Array(link_ids).map { |i| Integer(i) }
    return { rows: [], active_count: 0 } if ids.empty?

    dir = direction.to_s == "asc" ? "ASC" : "DESC"
    placeholders = {
      project_id: Integer(project_id),
      event_type: event_type.to_s,
      start_date: format_date(start_date),
      end_date: format_date(end_date),
      limit: Integer(limit),
      offset: Integer(offset)
    }
    where_sql = <<~SQL
      WHERE project_id = {project_id:UInt64}
        AND event_date >= {start_date:Date}
        AND event_date <= {end_date:Date}
        AND link_id IN (#{ids.join(',')})
    SQL

    # HAVING > 0 keeps the active set to links with THIS event type, so a link holding only
    # other event types joins the zero tail instead of sorting ahead of non-zero links on ASC.
    page_query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT link_id, sumIf(cnt, event_type = {event_type:String}) AS metric
        FROM link_daily
        #{where_sql}
        GROUP BY link_id
        HAVING metric > 0
        ORDER BY metric #{dir}, link_id ASC
        LIMIT {limit:UInt64} OFFSET {offset:UInt64}
      SQL
      placeholders: placeholders
    )
    count_query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT count() FROM (
          SELECT link_id
          FROM link_daily
          #{where_sql}
          GROUP BY link_id
          HAVING sumIf(cnt, event_type = {event_type:String}) > 0
        )
      SQL
      placeholders: placeholders.except(:limit, :offset)
    )

    Clickhouse.with do |conn|
      { rows: conn.select_all(page_query), active_count: conn.select_value(count_query).to_i }
    end
  rescue StandardError => e
    log_query_failure(:link_event_sorted_page, e)
    nil
  end

  # { link_id => average engaged-session seconds }; bounces excluded, divided once.
  def self.link_session_avg_seconds(project_id, link_ids:, start_date:, end_date:)
    return nil unless Clickhouse.read_enabled?

    ids = Array(link_ids).map { |i| Integer(i) }
    return {} if ids.empty?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT link_id, sum(engaged_sessions) AS sessions, sum(engaged_duration_ms_sum) AS duration_ms
        FROM link_session_daily
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
          AND link_id IN (#{ids.join(',')})
        GROUP BY link_id
        HAVING sessions > 0
      SQL
      placeholders: {
        project_id: Integer(project_id),
        start_date: format_date(start_date),
        end_date: format_date(end_date)
      }
    )
    Clickhouse.with { |conn| conn.select_all(query) }.to_h do |row|
      [row["link_id"].to_i, (row["duration_ms"].to_f / row["sessions"].to_i / 1000).round(2)]
    end
  rescue StandardError => e
    log_query_failure(:link_session_avg_seconds, e)
    nil
  end

  # Rollup-covered metrics — the ORDER BY whitelist (revenue is PG-only by design).
  ROLLUP_SORT_METRICS = %w[views opens installs reinstalls time_spent reactivations app_opens user_referred].freeze

  ROLLUP_METRIC_SUMS_SQL = ROLLUP_SORT_METRICS.map { |m| "sum(#{m}) AS #{m}" }.join(",\n          ").freeze

  # Campaign-grain totals from link_daily (event-time campaign_id — reassigning
  # a link does not move its history, unlike the PG current-links join).
  def self.campaign_metrics_daily(project_id, start_date:, end_date:, platform: nil)
    return nil unless Clickhouse.read_enabled?

    platform_clause = platform.present? ? "AND #{NORMALIZED_PLATFORM_SQL} = {platform:String}" : ''
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date)
    }
    placeholders[:platform] = platform.to_s if platform.present?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          campaign_id,
          sumIf(cnt, event_type = 'view')          AS views,
          sumIf(cnt, event_type = 'open')          AS opens,
          sumIf(cnt, event_type = 'install')       AS installs,
          sumIf(cnt, event_type = 'reinstall')     AS reinstalls,
          sumIf(total_engagement_time, event_type = 'time_spent') AS time_spent,
          sumIf(cnt, event_type = 'reactivation')  AS reactivations,
          sumIf(cnt, event_type = 'app_open')      AS app_opens,
          sumIf(cnt, event_type = 'user_referred') AS user_referred
        FROM link_daily
        WHERE project_id = {project_id:UInt64}
          AND campaign_id > 0
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
          #{platform_clause}
        GROUP BY campaign_id
      SQL
      placeholders: placeholders
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:campaign_metrics_daily, e)
    nil
  end

  # One metric-sorted page of link totals + count of links with rollup rows in
  # range; candidate ids come from the caller's PG filter set.
  def self.link_metrics_sorted_page(project_id, link_ids:, metric:, direction:, start_date:, end_date:,
                                    limit:, offset:, platform: nil)
    return nil unless Clickhouse.read_enabled?
    raise ArgumentError, "unsortable metric #{metric}" unless ROLLUP_SORT_METRICS.include?(metric.to_s)

    ids = Array(link_ids).map { |i| Integer(i) }
    return { rows: [], active_count: 0 } if ids.empty?

    dir = direction.to_s == "asc" ? "ASC" : "DESC"
    platform_clause = platform.present? ? "AND #{NORMALIZED_PLATFORM_SQL} = {platform:String}" : ''
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date),
      limit: Integer(limit),
      offset: Integer(offset)
    }
    placeholders[:platform] = platform.to_s if platform.present?
    where_sql = <<~SQL
      WHERE project_id = {project_id:UInt64}
        AND event_date >= {start_date:Date}
        AND event_date <= {end_date:Date}
        AND link_id IN (#{ids.join(',')})
        #{platform_clause}
    SQL

    page_query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          link_id,
          #{ROLLUP_METRIC_SUMS_SQL}
        FROM link_metrics_daily
        #{where_sql}
        GROUP BY link_id
        HAVING #{metric} > 0
        ORDER BY #{metric} #{dir}, link_id ASC
        LIMIT {limit:UInt64} OFFSET {offset:UInt64}
      SQL
      placeholders: placeholders
    )
    count_query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT count() FROM (
          SELECT link_id FROM link_metrics_daily
          #{where_sql}
          GROUP BY link_id
          HAVING sum(#{metric}) > 0
        )
      SQL
      placeholders: placeholders.except(:limit, :offset)
    )

    Clickhouse.with do |conn|
      { rows: conn.select_all(page_query), active_count: conn.select_value(count_query).to_i }
    end
  rescue StandardError => e
    log_query_failure(:link_metrics_sorted_page, e)
    nil
  end

  # Whole link list inside ClickHouse — no candidate id list, so no cap applies.
  def self.link_page_from_dimensions(project_id, metric:, direction:, start_date:, end_date:,
                                     limit:, offset:, platform: nil, filters: {})
    return nil unless Clickhouse.read_enabled?
    raise ArgumentError, "unsortable metric #{metric}" unless ROLLUP_SORT_METRICS.include?(metric.to_s)

    dir = direction.to_s == "asc" ? "ASC" : "DESC"
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date),
      offset: Integer(offset)
    }
    placeholders[:limit] = Integer(limit) unless limit.nil?
    dim_sql = link_dimension_predicates(filters, placeholders)
    # A non-numeric id filter matches nothing, exactly as the Postgres path returns [].
    return { rows: [], total: 0 } if dim_sql == :no_match
    platform_clause = platform.present? ? "AND #{NORMALIZED_PLATFORM_SQL} = {platform:String}" : ''
    placeholders[:platform] = platform.to_s if platform.present?

    dimension_sql = <<~SQL
      SELECT link_id FROM link_dimensions FINAL
      WHERE project_id = {project_id:UInt64} AND deleted = 0
      #{dim_sql}
    SQL

    # LEFT JOIN produces the zero tail: a link with no rollup rows still appears, with zeros.
    page_query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT d.link_id AS link_id, #{ROLLUP_SORT_METRICS.map { |m| "m.#{m} AS #{m}" }.join(', ')}
        FROM (#{dimension_sql}) AS d
        LEFT JOIN (
          SELECT link_id, #{ROLLUP_METRIC_SUMS_SQL}
          FROM link_metrics_daily
          WHERE project_id = {project_id:UInt64}
            AND event_date >= {start_date:Date}
            AND event_date <= {end_date:Date}
            #{platform_clause}
          GROUP BY link_id
        ) AS m ON m.link_id = d.link_id
        ORDER BY (m.#{metric} = 0) ASC, m.#{metric} #{dir}, d.link_id ASC
        #{limit.nil? ? '' : 'LIMIT {limit:UInt64} OFFSET {offset:UInt64}'}
      SQL
      placeholders: placeholders
    )
    # Membership depends only on the dimension, so the count must NOT repeat the join.
    count_query = ClickHouse::Client::Query.new(
      raw_query: "SELECT count() FROM (#{dimension_sql}) AS d",
      placeholders: placeholders.except(:limit, :offset, :platform, :start_date, :end_date)
    )

    Clickhouse.with do |conn|
      { rows: conn.select_all(page_query), total: conn.select_value(count_query).to_i }
    end
  rescue StandardError => e
    log_query_failure(:link_page_from_dimensions, e)
    nil
  end

  # One ordered id page, so reconciliation can walk a multi-million-link project without
  # pulling its whole id set into Ruby.
  def self.link_dimension_ids(project_id, after_id: 0, limit: 50_000)
    return nil unless Clickhouse.read_enabled?

    query = ClickHouse::Client::Query.new(
      raw_query: "SELECT link_id FROM link_dimensions FINAL " \
                 "WHERE project_id = {project_id:UInt64} AND deleted = 0 " \
                 "AND link_id > {after_id:UInt64} ORDER BY link_id ASC LIMIT {limit:UInt64}",
      placeholders: { project_id: Integer(project_id), after_id: Integer(after_id), limit: Integer(limit) }
    )
    Clickhouse.with { |conn| conn.select_all(query) }.map { |r| r["link_id"].to_i }
  rescue StandardError => e
    log_query_failure(:link_dimension_ids, e)
    nil
  end

  # Mirrors LinkStatisticsQuery#links_scope so both paths select the same links.
  def self.link_dimension_predicates(filters, placeholders)
    sql = +''
    sql << " AND active = {f_active:UInt8}" unless filters[:active].nil?
    placeholders[:f_active] = filters[:active] ? 1 : 0 unless filters[:active].nil?
    sql << " AND sdk_generated = {f_sdk:UInt8}" unless filters[:sdk_generated].nil?
    placeholders[:f_sdk] = filters[:sdk_generated] ? 1 : 0 unless filters[:sdk_generated].nil?
    if filters[:campaign_id].present?
      sql << " AND campaign_id = {f_campaign:UInt64}"
      placeholders[:f_campaign] = Integer(filters[:campaign_id])
    end
    if filters[:ads_platform].present?
      sql << " AND ads_platform = {f_ads:String}"
      placeholders[:f_ads] = filters[:ads_platform].to_s
    end
    if filters[:link_id].present?
      sql << " AND link_id = {f_link_id:UInt64}"
      placeholders[:f_link_id] = Integer(filters[:link_id])
    end
    if filters[:term].present?
      # UTF8 variants: staging/production run en_US.utf8, where Postgres ILIKE folds Cyrillic.
      sql << " AND (positionCaseInsensitiveUTF8(name, {f_term:String}) > 0" \
             " OR positionCaseInsensitiveUTF8(title, {f_term:String}) > 0" \
             " OR positionCaseInsensitiveUTF8(subtitle, {f_term:String}) > 0" \
             " OR positionCaseInsensitiveUTF8(path, {f_term:String}) > 0" \
             " OR arrayExists(t -> positionCaseInsensitiveUTF8(t, {f_term:String}) > 0, tags))"
      placeholders[:f_term] = filters[:term].to_s
    end
    sql
  rescue ArgumentError, TypeError
    :no_match
  end
  private_class_method :link_dimension_predicates

  # Ids with a NON-ZERO value for this metric — the complement is the zero tail. Keyed on
  # the metric, not mere row presence: a link with rows for OTHER metrics is still a zero.
  def self.link_active_ids(project_id, link_ids:, metric:, start_date:, end_date:, platform: nil)
    return nil unless Clickhouse.read_enabled?
    raise ArgumentError, "unsortable metric #{metric}" unless ROLLUP_SORT_METRICS.include?(metric.to_s)

    ids = Array(link_ids).map { |i| Integer(i) }
    return [] if ids.empty?

    platform_clause = platform.present? ? "AND #{NORMALIZED_PLATFORM_SQL} = {platform:String}" : ''
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date)
    }
    placeholders[:platform] = platform.to_s if platform.present?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT link_id
        FROM link_metrics_daily
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
          AND link_id IN (#{ids.join(',')})
          #{platform_clause}
        GROUP BY link_id
        HAVING sum(#{metric}) > 0
      SQL
      placeholders: placeholders
    )
    Clickhouse.with { |conn| conn.select_all(query) }.map { |r| r["link_id"].to_i }
  rescue StandardError => e
    log_query_failure(:link_active_ids, e)
    nil
  end

  # One ordered page of visitor totals + distinct-visitor count; `order` is a
  # rollup metric or "visitor_id" (created_at proxy — ids are insertion-ordered).
  def self.visitor_metrics_page(project_id, start_date:, end_date:, order:, direction:,
                                limit:, offset:, platform: nil, visitor_ids: nil)
    metrics_page_by_key("visitor_id", project_id, start_date: start_date, end_date: end_date,
                        order: order, direction: direction, limit: limit, offset: offset,
                        platform: platform, ids: visitor_ids)
  end

  IDENTITY_SORT_FIELDS = %w[sdk_identifier uuid].freeze

  # False until a generation is published; callers MUST fall back to PG or search returns nothing.
  def self.visitor_identity_coverage?(project_id)
    return false unless Clickhouse.read_enabled?

    published_identity_generation?(project_id)
  end

  # Independent of both routing flags: the sync writes directly, cutover backfills with reads off.
  def self.published_identity_generation?(project_id)
    query = ClickHouse::Client::Query.new(
      raw_query: "SELECT 1 FROM visitor_identities WHERE project_id = {project_id:UInt64} " \
                 "AND visitor_id = #{Analytics::VisitorIdentitySyncService::GENERATION_MARKER_VISITOR_ID} LIMIT 1",
      placeholders: { project_id: Integer(project_id) }
    )
    Clickhouse.with { |conn| conn.select_value(query) }.to_i == 1
  rescue StandardError => e
    log_query_failure(:published_identity_generation, e)
    false
  end

  # LEFT JOIN, never INNER: a visitor lacking an identity row must stay in the population.
  def self.visitor_metrics_page_by_identity(project_id, start_date:, end_date:, order:, direction:,
                                            limit:, offset:, platform: nil, visitor_ids: nil, term: nil)
    return nil unless Clickhouse.read_enabled?
    raise ArgumentError, "unsortable identity order #{order}" unless IDENTITY_SORT_FIELDS.include?(order.to_s)

    ids = visitor_ids.nil? ? nil : Array(visitor_ids).map { |i| Integer(i) }
    return { rows: [], total: 0 } if ids && ids.empty?

    dir = direction.to_s == "asc" ? "ASC" : "DESC"
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date),
      limit: Integer(limit),
      offset: Integer(offset)
    }
    placeholders[:platform] = platform.to_s if platform.present?
    # ILIKE with the same %term% pattern PG builds, so `%`/`_` stay wildcards on both stores.
    placeholders[:term] = "%#{term}%" if term.present?

    where_sql = [
      "WHERE m.project_id = {project_id:UInt64}",
      "AND m.event_date >= {start_date:Date}",
      "AND m.event_date <= {end_date:Date}",
      ids ? "AND m.visitor_id IN (#{ids.join(',')})" : nil
    ].compact.join("\n  ")
    where_sql += "\n  AND #{NORMALIZED_PLATFORM_SQL} = {platform:String}" if platform.present?
    if term.present?
      where_sql += "\n  AND (up.sdk_identifier ILIKE {term:String} OR up.uuid ILIKE {term:String})"
    end

    # Compared at ms so a same-ms live profile ties and wins on `live`, not on ns precision.
    join_sql = <<~SQL
      LEFT JOIN (
        SELECT visitor_id,
               argMax(sdk_identifier, (observed_at, live)) AS sdk_identifier,
               argMax(uuid, (observed_at, live)) AS uuid
        FROM (
          SELECT visitor_id, sdk_identifier, uuid, toDateTime64(synced_at, 3) AS observed_at, 0 AS live
          FROM visitor_identities
          WHERE project_id = {project_id:UInt64}
            AND visitor_id != #{Analytics::VisitorIdentitySyncService::GENERATION_MARKER_VISITOR_ID}
            AND synced_at = #{Analytics::VisitorIdentitySyncService.published_generation_sql(project_id)}
          UNION ALL
          SELECT visitor_id, sdk_identifier, uuid, last_seen AS observed_at, 1 AS live
          FROM user_profiles
          WHERE project_id = {project_id:UInt64}
        )
        GROUP BY visitor_id
      ) up ON up.visitor_id = m.visitor_id
    SQL

    page_query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          m.visitor_id AS visitor_id,
          #{ROLLUP_METRIC_SUMS_SQL}
        FROM visitor_metrics_daily m
        #{join_sql}
        #{where_sql}
        GROUP BY m.visitor_id, up.#{order}
        ORDER BY (up.#{order} = '') #{dir}, up.#{order} #{dir}, m.visitor_id ASC
        LIMIT {limit:UInt64} OFFSET {offset:UInt64}
      SQL
      placeholders: placeholders
    )
    count_query = ClickHouse::Client::Query.new(
      raw_query: "SELECT uniqExact(m.visitor_id) FROM visitor_metrics_daily m #{join_sql} #{where_sql}",
      placeholders: placeholders.except(:limit, :offset)
    )

    Clickhouse.with do |conn|
      { rows: conn.select_all(page_query), total: conn.select_value(count_query).to_i }
    end
  rescue StandardError => e
    log_query_failure(:visitor_metrics_page_by_identity, e)
    nil
  end

  # Rows carry the inviter under "visitor_id" so callers share one hydration path.
  def self.inviter_metrics_page(project_id, start_date:, end_date:, order:, direction:,
                                limit:, offset:, platform: nil, inviter_ids: nil)
    metrics_page_by_key("inviter_id", project_id, start_date: start_date, end_date: end_date,
                        order: order, direction: direction, limit: limit, offset: offset,
                        platform: platform, ids: inviter_ids)
  end

  # Candidate ids with rollup rows in range; the caller holds the order. nil on failure.
  def self.visitor_active_ids(project_id, visitor_ids:, start_date:, end_date:, platform: nil)
    active_ids_by_key("visitor_id", project_id, ids: visitor_ids, start_date: start_date,
                                    end_date: end_date, platform: platform)
  end

  def self.inviter_active_ids(project_id, inviter_ids:, start_date:, end_date:, platform: nil)
    active_ids_by_key("inviter_id", project_id, ids: inviter_ids, start_date: start_date,
                                    end_date: end_date, platform: platform)
  end

  # Every inviter CH has rows for in range, capped. This IS the referral population, so
  # ordering it in PG cannot disagree with the metric-sorted path. nil on failure.
  def self.inviter_population_ids(project_id, start_date:, end_date:, limit:, platform: nil)
    return nil unless Clickhouse.read_enabled?

    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date),
      limit: Integer(limit)
    }
    placeholders[:platform] = platform.to_s if platform.present?
    platform_clause = platform.present? ? "AND #{NORMALIZED_PLATFORM_SQL} = {platform:String}" : ""

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT DISTINCT #{EFFECTIVE_INVITER_SQL} AS id
        FROM visitor_metrics_daily
        #{IDENTITY_MAP_JOINS}
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
          AND inviter_id != 0
          AND #{NON_SELF_INVITER_SQL}
          #{platform_clause}
        LIMIT {limit:UInt64}
      SQL
      placeholders: placeholders
    )
    Clickhouse.with { |conn| conn.select_all(query) }.map { |r| r["id"].to_i }
  rescue StandardError => e
    log_query_failure(:inviter_population_ids, e)
    nil
  end

  PAGE_KEYS = %w[visitor_id inviter_id].freeze

  def self.identity_join(als, column)
    "LEFT JOIN (SELECT from_visitor_id, to_visitor_id FROM visitor_identity_map FINAL " \
    "WHERE project_id = {project_id:UInt64}) AS #{als} " \
    "ON visitor_metrics_daily.#{column} = #{als}.from_visitor_id"
  end
  private_class_method :identity_join

  # A merge repoints the inviter in PG only; the rebuild groups the raw column, so fold here.
  IDENTITY_MAP_JOINS = [identity_join("vim", "inviter_id"), identity_join("vim_v", "visitor_id")].join("\n")
  EFFECTIVE_INVITER_SQL = "if(vim.to_visitor_id > 0, vim.to_visitor_id, visitor_metrics_daily.inviter_id)"
  EFFECTIVE_INVITEE_SQL = "if(vim_v.to_visitor_id > 0, vim_v.to_visitor_id, visitor_metrics_daily.visitor_id)"

  # Gate on the join flags, not raw equality: a self-invite's raw ids stay equal through a merge.
  NON_SELF_INVITER_SQL = "(#{EFFECTIVE_INVITER_SQL} != #{EFFECTIVE_INVITEE_SQL} " \
                         "OR (vim.to_visitor_id = 0 AND vim_v.to_visitor_id = 0))"

  def self.page_key_expr(key) = key == "inviter_id" ? EFFECTIVE_INVITER_SQL : key
  private_class_method :page_key_expr

  def self.page_key_join(key) = key == "inviter_id" ? IDENTITY_MAP_JOINS : ""
  private_class_method :page_key_join

  def self.page_key_where(key, ids)
    [
      "WHERE project_id = {project_id:UInt64}",
      "AND event_date >= {start_date:Date}",
      "AND event_date <= {end_date:Date}",
      key == "inviter_id" ? "AND inviter_id != 0\n  AND #{NON_SELF_INVITER_SQL}" : nil, # PG's invited_by_id NOT NULL
      ids ? "AND #{page_key_expr(key)} IN (#{ids.join(',')})" : nil
    ].compact.join("\n  ")
  end
  private_class_method :page_key_where

  def self.metrics_page_by_key(key, project_id, start_date:, end_date:, order:, direction:,
                               limit:, offset:, platform:, ids:)
    return nil unless Clickhouse.read_enabled?
    raise ArgumentError, "unknown page key #{key}" unless PAGE_KEYS.include?(key)

    allowed = ROLLUP_SORT_METRICS + ["visitor_id"]
    raise ArgumentError, "unsortable order #{order}" unless allowed.include?(order.to_s)

    ids = ids.nil? ? nil : Array(ids).map { |i| Integer(i) }
    return { rows: [], total: 0 } if ids && ids.empty?

    dir = direction.to_s == "asc" ? "ASC" : "DESC"
    key_sql = page_key_expr(key)
    order_sql = order.to_s == "visitor_id" ? "#{key_sql} #{dir}" : "#{order} #{dir}, #{key_sql} ASC"
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date),
      limit: Integer(limit),
      offset: Integer(offset)
    }
    placeholders[:platform] = platform.to_s if platform.present?
    where_sql = page_key_where(key, ids)
    where_sql += "\n  AND #{NORMALIZED_PLATFORM_SQL} = {platform:String}" if platform.present?

    page_query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          #{key_sql} AS visitor_id,
          #{ROLLUP_METRIC_SUMS_SQL}
        FROM visitor_metrics_daily
        #{page_key_join(key)}
        #{where_sql}
        GROUP BY #{key_sql}
        ORDER BY #{order_sql}
        LIMIT {limit:UInt64} OFFSET {offset:UInt64}
      SQL
      placeholders: placeholders
    )
    count_query = ClickHouse::Client::Query.new(
      raw_query: "SELECT uniqExact(#{key_sql}) FROM visitor_metrics_daily " \
                 "#{page_key_join(key)} #{where_sql}",
      placeholders: placeholders.except(:limit, :offset)
    )

    Clickhouse.with do |conn|
      { rows: conn.select_all(page_query), total: conn.select_value(count_query).to_i }
    end
  rescue StandardError => e
    log_query_failure(:"#{key.delete_suffix('_id')}_metrics_page", e)
    nil
  end
  private_class_method :metrics_page_by_key

  def self.active_ids_by_key(key, project_id, ids:, start_date:, end_date:, platform:)
    return nil unless Clickhouse.read_enabled?
    raise ArgumentError, "unknown page key #{key}" unless PAGE_KEYS.include?(key)

    ids = Array(ids).map { |i| Integer(i) }
    return [] if ids.empty?

    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date)
    }
    placeholders[:platform] = platform.to_s if platform.present?
    where_sql = page_key_where(key, ids)
    where_sql += "\n  AND #{NORMALIZED_PLATFORM_SQL} = {platform:String}" if platform.present?

    query = ClickHouse::Client::Query.new(
      raw_query: "SELECT DISTINCT #{page_key_expr(key)} AS id FROM visitor_metrics_daily " \
                 "#{page_key_join(key)} #{where_sql}",
      placeholders: placeholders
    )
    Clickhouse.with { |conn| conn.select_all(query) }.map { |r| r["id"].to_i }
  rescue StandardError => e
    log_query_failure(:"#{key.delete_suffix('_id')}_active_ids", e)
    nil
  end
  private_class_method :active_ids_by_key

  # Daily per-event-type rows (date, event_type, count, avg engagement) for the
  # overview charts, from raw CH events. Serves the events/overview and
  # campaigns/metrics_overview endpoints (which scan raw PG events today). All
  # filters map to CH events columns; link.active is NOT here, so the caller only
  # routes to CH when no active filter is requested. campaign_ids: nil = no filter,
  # [] = match nothing (mirrors PG `where(link: {campaign_id: []})`).
  def self.event_overview_rows(project_ids, start_date:, end_date:, campaign_ids: nil,
                               sdk_generated: nil, ads_platform: nil,
                               app_versions: nil, build_versions: nil, platforms: nil)
    # nil = CH unavailable (disabled or errored) → caller falls back to PG. A
    # successful query returns an array (possibly empty). Filters mirror the PG
    # `unless x.nil?` semantics (a non-nil "" or [] filters, matching nothing).
    #
    # NOTE (event-time vs current link): campaign_id/sdk_generated/ads_platform are
    # the event-time snapshot on the CH events row, whereas the PG path joins `links`
    # and filters the link's CURRENT attributes. Reassigning a link's campaign/metadata
    # therefore shifts historical PG results but not CH ones. CH's rollups are all
    # event-time-attributed, so this is consistent with the rest of the CH model.
    return nil unless Clickhouse.read_enabled?

    pids = Array(project_ids).map { |i| Integer(i) }
    return [] if pids.empty?
    return [] if !campaign_ids.nil? && Array(campaign_ids).empty?

    placeholders = { start_date: format_date(start_date), end_date: format_date(end_date) }
    clauses = ["project_id IN (#{pids.join(',')})",
               "toDate(created_at) >= {start_date:Date}",
               "toDate(created_at) <= {end_date:Date}"]

    unless campaign_ids.nil?
      ids = Array(campaign_ids).map { |i| Integer(i) }
      clauses << "campaign_id IN (#{ids.join(',')})"
    end
    unless sdk_generated.nil?
      placeholders[:sdk_generated] = ActiveModel::Type::Boolean.new.cast(sdk_generated) ? 1 : 0
      clauses << "sdk_generated = {sdk_generated:UInt8}"
    end
    unless ads_platform.nil?
      placeholders[:ads_platform] = ads_platform.to_s
      clauses << "ads_platform = {ads_platform:String}"
    end
    clauses << string_in_clause("app_version", "av", app_versions, placeholders) unless app_versions.nil?
    clauses << string_in_clause("build", "bv", build_versions, placeholders) unless build_versions.nil?
    clauses << string_in_clause("platform", "pf", platforms, placeholders) unless platforms.nil?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          toDate(created_at)    AS date,
          event_type,
          count()               AS count,
          -- skip zeros (=PG's NULLs) and map avgIf's nan to 0, to match PG AVG.
          ifNotFinite(avgIf(engagement_time, engagement_time != 0), 0) AS avg_engagement_time
        FROM events FINAL
        WHERE #{clauses.join(' AND ')}
        GROUP BY date, event_type
        ORDER BY date, event_type
        SETTINGS do_not_merge_across_partitions_select_final = 1, #{QUERY_GUARD_PAIRS}
      SQL
      placeholders: placeholders
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:event_overview_rows, e)
    nil
  end

  # IN clause over string values using generated named placeholders (no Array
  # support). Empty values → a never-true predicate, mirroring PG `col IN []`.
  def self.string_in_clause(column, prefix, values, placeholders)
    # compact: a nil would become '' here but IS NULL on the PG path — guard it.
    vals = Array(values).compact
    return "1 = 0" if vals.empty?

    keys = vals.each_with_index.map do |v, i|
      key = "#{prefix}#{i}".to_sym
      placeholders[key] = v.to_s
      "{#{key}:String}"
    end
    "#{column} IN (#{keys.join(', ')})"
  end
  private_class_method :string_in_clause

  # Filter dropdowns. Unbounded scan → guarded + cached; trimBoth mirrors compact_blank.
  FILTER_VALUES_CACHE_TTL = 5.minutes

  def self.event_filter_values(project_id)
    return nil unless Clickhouse.read_enabled?

    Rails.cache.fetch("ch:event_filter_values:#{Integer(project_id)}", expires_in: FILTER_VALUES_CACHE_TTL) do
      query = ClickHouse::Client::Query.new(
        raw_query: <<~SQL,
          SELECT
            arraySort(groupUniqArrayIf(platform, trimBoth(platform) != ''))       AS platforms,
            arraySort(groupUniqArrayIf(app_version, trimBoth(app_version) != '')) AS app_versions,
            arraySort(groupUniqArrayIf(build, trimBoth(build) != ''))             AS builds
          FROM events
          WHERE project_id = {project_id:UInt64}
          #{BILLING_QUERY_GUARD}
        SQL
        placeholders: { project_id: Integer(project_id) }
      )
      row = Clickhouse.with { |conn| conn.select_all(query).first } || {}
      {
        platforms: Array(row["platforms"]),
        app_versions: Array(row["app_versions"]),
        builds: Array(row["builds"])
      }
    end
  rescue StandardError => e
    log_query_failure(:event_filter_values, e)
    nil
  end

  # Visitor-level daily stats.
  def self.visitor_daily_stats(project_id, visitor_id:, start_date:, end_date:)
    return [] unless Clickhouse.read_enabled?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          event_date,
          event_type,
          platform,
          sum(cnt)                   AS cnt,
          sum(total_engagement_time) AS total_engagement_time
        FROM visitor_daily
        WHERE project_id = {project_id:UInt64}
          AND visitor_id = {visitor_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
        GROUP BY event_date, event_type, platform
        ORDER BY event_date, event_type, platform
      SQL
      placeholders: {
        project_id: Integer(project_id),
        visitor_id: Integer(visitor_id),
        start_date: format_date(start_date),
        end_date: format_date(end_date)
      }
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:visitor_daily_stats, e)
    []
  end

  # Revenue by project, date, store_source.
  def self.purchase_project_daily_stats(project_id, start_date:, end_date:)
    return [] unless Clickhouse.read_enabled?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          event_date,
          event_type,
          store_source,
          sum(total_revenue_cents) AS total_revenue_cents,
          sum(units)             AS units,
          uniqExact(visitor_id)  AS paying_visitors
        FROM purchase_project_daily FINAL
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
        GROUP BY event_date, event_type, store_source
        ORDER BY event_date, event_type, store_source
      SQL
      placeholders: {
        project_id: Integer(project_id),
        start_date: format_date(start_date),
        end_date: format_date(end_date)
      }
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:purchase_project_daily_stats, e)
    []
  end

  # Signed, quantity-weighted revenue by product, date — reads the signed
  # ReplacingMergeTree rollup (FINAL dedups replayed transactions).
  def self.purchase_product_daily_stats(project_id, product_id:, start_date:, end_date:)
    return [] unless Clickhouse.read_enabled?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          event_date,
          event_type,
          store_source,
          sum(total_revenue_cents) AS total_revenue_cents,
          sum(units)               AS units
        FROM purchase_product_daily FINAL
        WHERE project_id = {project_id:UInt64}
          AND product_id = {product_id:String}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
        GROUP BY event_date, event_type, store_source
        ORDER BY event_date, event_type, store_source
      SQL
      placeholders: {
        project_id: Integer(project_id),
        product_id: product_id.to_s,
        start_date: format_date(start_date),
        end_date: format_date(end_date)
      }
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:purchase_product_daily_stats, e)
    []
  end

  # Country breakdown by project, date.
  def self.project_country_daily_stats(project_id, start_date:, end_date:)
    return [] unless Clickhouse.read_enabled?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          event_date,
          country,
          event_type,
          platform,
          sum(cnt)                    AS cnt,
          uniqMerge(visitors_state)   AS unique_visitors
        FROM project_country_daily
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
        GROUP BY event_date, country, event_type, platform
        ORDER BY event_date, country, event_type, platform
      SQL
      placeholders: {
        project_id: Integer(project_id),
        start_date: format_date(start_date),
        end_date: format_date(end_date)
      }
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:project_country_daily_stats, e)
    []
  end

  # Top app versions per platform from the version rollup.
  def self.project_version_daily_stats(project_id, start_date:, end_date:, platform: nil, limit_per_platform: 10)
    return [] unless Clickhouse.read_enabled?

    platform_filter = platform.present? ? "AND #{NORMALIZED_PLATFORM_SQL} = {platform:String}" : ""
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date),
      limit: Integer(limit_per_platform)
    }
    placeholders[:platform] = normalize_platform_value(platform) if platform.present?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT platform, version, cnt, users
        FROM (
          SELECT
            platform,
            if(app_version = '', 'Unknown', app_version) AS version,
            sum(cnt) AS cnt,
            uniqMerge(visitors_state) AS users,
            row_number() OVER (PARTITION BY platform ORDER BY users DESC, version ASC) AS rn
          FROM project_version_daily
          WHERE project_id = {project_id:UInt64}
            AND event_date >= {start_date:Date}
            AND event_date <= {end_date:Date}
            #{platform_filter}
          GROUP BY platform, version
        )
        WHERE rn <= {limit:UInt32}
        ORDER BY platform, users DESC, version ASC
      SQL
      placeholders: placeholders
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:project_version_daily_stats, e)
    []
  end

  # First-seen release date per version from all historical rollup partitions.
  def self.project_version_release_dates(project_id, versions)
    return [] unless Clickhouse.read_enabled?

    normalized_versions = Array(versions).map(&:to_s).uniq
    return [] if normalized_versions.empty?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          if(app_version = '', 'Unknown', app_version) AS version,
          toDate(min(first_seen)) AS release_date
        FROM project_version_daily
        WHERE project_id = {project_id:UInt64}
          AND if(app_version = '', 'Unknown', app_version) IN {versions:Array(String)}
        GROUP BY version
      SQL
      placeholders: {
        project_id: Integer(project_id),
        versions: normalized_versions
      }
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:project_version_release_dates, e)
    []
  end

  # Per-platform split for the top overall versions in a date range.
  def self.project_version_distribution_stats(project_id, start_date:, end_date:, platform: nil, limit: 10)
    return [] unless Clickhouse.read_enabled?

    platform_filter = platform.present? ? "AND platform = {platform:String}" : ""
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date),
      limit: Integer(limit)
    }
    placeholders[:platform] = platform.to_s if platform.present?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        WITH top_versions AS (
          SELECT if(app_version = '', 'Unknown', app_version) AS version
          FROM project_version_daily
          WHERE project_id = {project_id:UInt64}
            AND event_date >= {start_date:Date}
            AND event_date <= {end_date:Date}
            #{platform_filter}
          GROUP BY version
          ORDER BY uniqMerge(visitors_state) DESC, version ASC
          LIMIT {limit:UInt32}
        )
        SELECT
          if(app_version = '', 'Unknown', app_version) AS version,
          platform,
          uniqMerge(visitors_state) AS users
        FROM project_version_daily
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
          AND if(app_version = '', 'Unknown', app_version) IN (SELECT version FROM top_versions)
          #{platform_filter}
        GROUP BY version, platform
        ORDER BY version ASC, platform ASC
      SQL
      placeholders: placeholders
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:project_version_distribution_stats, e)
    []
  end

  # Unique visitors by current source classifier.
  def self.project_source_daily_stats(project_id, start_date:, end_date:, platform: nil)
    return [] unless Clickhouse.read_enabled?

    platform_filter = platform.present? ? "AND #{NORMALIZED_PLATFORM_SQL} = {platform:String}" : ""
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date)
    }
    placeholders[:platform] = normalize_platform_value(platform) if platform.present?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          source,
          sum(cnt) AS cnt,
          uniqMerge(visitors_state) AS visitors
        FROM project_source_daily
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
          #{platform_filter}
        GROUP BY source
        ORDER BY visitors DESC, source ASC
      SQL
      placeholders: placeholders
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:project_source_daily_stats, e)
    []
  end

  # Curated JSON property buckets. Arbitrary property exploration should stay raw.
  def self.project_property_daily_stats(project_id, start_date:, end_date:, property_key: nil, property_value: nil, event_type: nil, platform: nil)
    return [] unless Clickhouse.read_enabled?

    filters = []
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date)
    }

    if property_key
      filters << "AND property_key = {property_key:String}"
      placeholders[:property_key] = property_key.to_s
    end
    if property_value
      filters << "AND property_value = {property_value:String}"
      placeholders[:property_value] = property_value.to_s
    end
    if event_type
      filters << "AND event_type = {event_type:String}"
      placeholders[:event_type] = event_type.to_s
    end
    if platform.present?
      filters << "AND platform = {platform:String}"
      placeholders[:platform] = platform.to_s
    end

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          event_date,
          property_key,
          property_value,
          event_type,
          platform,
          sum(cnt) AS cnt,
          uniqMerge(visitors_state) AS unique_visitors
        FROM project_property_daily
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
          #{filters.join("\n          ")}
        GROUP BY event_date, property_key, property_value, event_type, platform
        ORDER BY event_date, property_key, property_value, event_type, platform
      SQL
      placeholders: placeholders
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:project_property_daily_stats, e)
    []
  end

  # Legacy organic formula: per-(date,platform) clamp, toInt64 first (UInt64 wraps); nil on failure.
  def self.organic_users_total(project_id, start_date:, end_date:, platform: nil)
    return nil unless Clickhouse.read_enabled?

    platforms = Array(platform).map(&:to_s).reject(&:empty?)
    platform_filter = platforms.empty? ? "" : "AND #{NORMALIZED_PLATFORM_SQL} IN {platforms:Array(String)}"
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date)
    }
    placeholders[:platforms] = platforms unless platforms.empty?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT sum(greatest(v.installs + v.reinstalls - coalesce(l.link_installs, 0), 0)) AS organic_users
        FROM (
          SELECT
            event_date,
            #{NORMALIZED_PLATFORM_SQL} AS metric_platform,
            toInt64(sum(installs))   AS installs,
            toInt64(sum(reinstalls)) AS reinstalls
          FROM visitor_metrics_daily
          WHERE project_id = {project_id:UInt64}
            AND event_date >= {start_date:Date}
            AND event_date <= {end_date:Date}
            #{platform_filter}
          GROUP BY event_date, metric_platform
        ) AS v
        LEFT JOIN (
          SELECT
            event_date,
            #{NORMALIZED_PLATFORM_SQL} AS metric_platform,
            toInt64(sum(installs)) AS link_installs
          FROM link_metrics_daily
          WHERE project_id = {project_id:UInt64}
            AND event_date >= {start_date:Date}
            AND event_date <= {end_date:Date}
            #{platform_filter}
          GROUP BY event_date, metric_platform
        ) AS l USING (event_date, metric_platform)
        #{BILLING_QUERY_GUARD}
      SQL
      placeholders: placeholders
    )
    row = Clickhouse.with { |conn| conn.select_all(query).first }
    row ? row["organic_users"].to_i : 0
  rescue StandardError => e
    log_query_failure(:organic_users_total, e)
    nil
  end

  # Mirrors PG link_views = SUM(link_daily_statistics.views); nil on disabled/failure.
  def self.link_views_total(project_id, start_date:, end_date:, platform: nil)
    return nil unless Clickhouse.read_enabled?

    platforms = Array(platform).map(&:to_s).reject(&:empty?)
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date)
    }
    placeholders[:platforms] = platforms unless platforms.empty?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT sum(views) AS link_views
        FROM link_metrics_daily
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
          #{platforms.empty? ? '' : "AND #{NORMALIZED_PLATFORM_SQL} IN {platforms:Array(String)}"}
        #{BILLING_QUERY_GUARD}
      SQL
      placeholders: placeholders
    )
    row = Clickhouse.with { |conn| conn.select_all(query).first }
    row ? row["link_views"].to_i : 0
  rescue StandardError => e
    log_query_failure(:link_views_total, e)
    nil
  end

  # DISTINCT referred people over the range. PG sums per-day row counts instead, which
  # counts a visitor once per active day (~4x on staging) and is inconsistent with every
  # other people-metric on the same dashboard row. Corrected here; see the cutover plan.
  def self.referred_users_total(project_id, start_date:, end_date:, platform: nil)
    return nil unless Clickhouse.read_enabled?

    platforms = Array(platform).map(&:to_s).reject(&:empty?)
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date)
    }
    placeholders[:platforms] = platforms unless platforms.empty?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT uniqExact(#{EFFECTIVE_INVITEE_SQL}) AS referred_users
        FROM visitor_metrics_daily
        #{IDENTITY_MAP_JOINS}
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
          AND inviter_id != 0
          AND #{NON_SELF_INVITER_SQL}
          #{platforms.empty? ? '' : "AND #{NORMALIZED_PLATFORM_SQL} IN {platforms:Array(String)}"}
        #{BILLING_QUERY_GUARD}
      SQL
      placeholders: placeholders
    )
    row = Clickhouse.with { |conn| conn.select_all(query).first }
    row ? row["referred_users"].to_i : 0
  rescue StandardError => e
    log_query_failure(:referred_users_total, e)
    nil
  end

  # { Date => link_views } in ONE query — the parity gate compares per day.
  def self.link_views_by_day(project_id, start_date:, end_date:)
    return nil unless Clickhouse.read_enabled?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT event_date, sum(views) AS link_views
        FROM link_metrics_daily
        WHERE project_id = {project_id:UInt64}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
        GROUP BY event_date
        #{BILLING_QUERY_GUARD}
      SQL
      placeholders: {
        project_id: Integer(project_id),
        start_date: format_date(start_date),
        end_date: format_date(end_date)
      }
    )
    rows_by_day(Clickhouse.with { |conn| conn.select_all(query) }, "link_views")
  rescue StandardError => e
    log_query_failure(:link_views_by_day, e)
    nil
  end

  def self.rows_by_day(rows, column)
    rows.to_h { |r| [Date.parse(r["event_date"].to_s), r[column].to_i] }
  end
  private_class_method :rows_by_day

  # Countable types only, as the unfiltered tile and PG count: a platform filter must narrow the
  # population, not redefine "user". No FINAL — this distinct-counts a key column, never a state.
  def self.unique_visitors_by_platform(project_id, start_date:, end_date:, platforms:)
    return nil unless Clickhouse.read_enabled?

    plats = Array(platforms).map(&:to_s).reject(&:empty?).map { |p| normalize_platform_value(p) }.uniq
    return nil if plats.empty?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT uniqExact(visitor_id) AS unique_visitors
        FROM visitor_daily
        WHERE project_id = {project_id:UInt64}
          AND visitor_id > 0
          AND event_type IN #{ClickhouseRollupRebuildService::COUNTABLE_TYPES_SQL}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
          AND #{NORMALIZED_PLATFORM_SQL} IN {platforms:Array(String)}
        #{BILLING_QUERY_GUARD}
      SQL
      placeholders: {
        project_id: Integer(project_id),
        start_date: format_date(start_date),
        end_date: format_date(end_date),
        platforms: plats
      }
    )
    row = Clickhouse.with { |conn| conn.select_all(query).first }
    row ? row["unique_visitors"].to_i : 0
  rescue StandardError => e
    log_query_failure(:unique_visitors_by_platform, e)
    nil
  end

  # Buckets for active_visitors_series: CH bucket expression + result-key formatter.
  ACTIVE_VISITOR_GROUPINGS = {
    day: { expr: "event_date", key: ->(date) { date } },
    month: { expr: "toStartOfMonth(event_date)", key: ->(date) { date.strftime("%Y-%m") } }
  }.freeze

  # :day → {Date => count}; :month → {"YYYY-MM" => count}, months deduped in CH.
  # nil on disabled/failure; {} when CH succeeded with no data.
  def self.active_visitors_series(project_ids, start_date:, end_date:, grouping:)
    bucket = ACTIVE_VISITOR_GROUPINGS[grouping]
    raise ArgumentError, "grouping must be :day or :month" unless bucket

    fetch_active_visitors_series(project_ids, start_date, end_date, bucket)
  end

  def self.fetch_active_visitors_series(project_ids, start_date, end_date, bucket)
    return nil unless Clickhouse.read_enabled?

    ids = Array(project_ids).map { |project_id| Integer(project_id) }
    return {} if ids.empty?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          #{bucket[:expr]} AS bucket,
          uniqExactMerge(visitors_state) AS active_visitors
        FROM billing_active_visitors_daily
        WHERE project_id IN {project_ids:Array(UInt64)}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
        GROUP BY bucket
        #{BILLING_QUERY_GUARD}
      SQL
      placeholders: {
        project_ids: ids,
        start_date: format_date(start_date),
        end_date: format_date(end_date)
      }
    )
    rows = Clickhouse.with { |conn| conn.select_all(query) }
    rows.to_h { |row| [bucket[:key].call(Date.parse(row["bucket"].to_s)), row["active_visitors"].to_i] }
  rescue StandardError => e
    log_query_failure(:active_visitors_series, e)
    nil
  end
  private_class_method :fetch_active_visitors_series

  # Exact range-distinct active visitor count. Use this for one billing month
  # only; multi-month billing must use billing_active_visitors_per_month_total
  # so visitors active in multiple months are counted once per month.
  # Returns nil when ClickHouse reads are unavailable so callers can fall back
  # instead of billing from an accidental zero.
  def self.billing_active_visitors(project_ids, start_date:, end_date:)
    return nil unless Clickhouse.read_enabled?

    ids = Array(project_ids).map { |project_id| Integer(project_id) }
    return 0 if ids.empty?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT uniqExactMerge(visitors_state) AS active_visitors
        FROM billing_active_visitors_daily
        WHERE project_id IN {project_ids:Array(UInt64)}
          AND event_date >= {start_date:Date}
          AND event_date <= {end_date:Date}
        #{BILLING_QUERY_GUARD}
      SQL
      placeholders: {
        project_ids: ids,
        start_date: format_date(start_date),
        end_date: format_date(end_date)
      }
    )
    row = Clickhouse.with { |conn| conn.select_all(query).first }
    row ? row['active_visitors'].to_i : 0
  rescue StandardError => e
    log_query_failure(:billing_active_visitors, e)
    nil
  end

  # Exact billing total matching ProjectService#compute_maus_per_month_total:
  # distinct active visitors per calendar month, summed across months.
  def self.billing_active_visitors_per_month_total(project_ids, start_date:, end_date:)
    return nil unless Clickhouse.read_enabled?

    ids = Array(project_ids).map { |project_id| Integer(project_id) }
    return 0 if ids.empty?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT sum(active_visitors) AS active_visitors
        FROM (
          SELECT
            toStartOfMonth(event_date) AS billing_month,
            uniqExactMerge(visitors_state) AS active_visitors
          FROM billing_active_visitors_daily
          WHERE project_id IN {project_ids:Array(UInt64)}
            AND event_date >= {start_date:Date}
            AND event_date <= {end_date:Date}
          GROUP BY billing_month
        )
        #{BILLING_QUERY_GUARD}
      SQL
      placeholders: {
        project_ids: ids,
        start_date: format_date(start_date.to_date.beginning_of_month),
        end_date: format_date(end_date)
      }
    )
    row = Clickhouse.with { |conn| conn.select_all(query).first }
    row ? row['active_visitors'].to_i : 0
  rescue StandardError => e
    log_query_failure(:billing_active_visitors_per_month_total, e)
    nil
  end

  # Merge-aware exact count from events FINAL + identity map — the ONLY billing read in
  # primary mode (the rebuild-fed rollup can over-report between rebuilds). nil on failure.
  def self.billing_active_visitors_exact(project_ids, start_date:, end_date:)
    return nil unless Clickhouse.read_enabled?

    ids = Array(project_ids).map { |project_id| Integer(project_id) }
    return 0 if ids.empty?

    effective_visitor = ClickhouseRollupRebuildService.effective_visitor_id_expr
    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT uniqExact(#{effective_visitor}) AS active_visitors
        #{ClickhouseRollupRebuildService::FROM_WITH_IDENTITY_MAP}
        WHERE events.project_id IN {project_ids:Array(UInt64)}
          AND toDate(created_at) >= {start_date:Date}
          AND toDate(created_at) <= {end_date:Date}
          AND #{effective_visitor} != 0
          AND event_type IN #{ClickhouseRollupRebuildService::COUNTABLE_TYPES_SQL}
        #{BILLING_QUERY_GUARD}
      SQL
      placeholders: {
        project_ids: ids,
        start_date: format_date(start_date),
        end_date: format_date(end_date)
      }
    )
    row = Clickhouse.with { |conn| conn.select_all(query).first }
    row ? row['active_visitors'].to_i : 0
  rescue StandardError => e
    log_query_failure(:billing_active_visitors_exact, e)
    nil
  end

  # Per (date, platform) first_time_visitors + new_users, mirroring PG
  # fetch_visitor_classification. nil on failure — never indistinguishable from zero.
  def self.first_seen_daily(project_id, start_date:, end_date:, platform: nil)
    return nil unless Clickhouse.read_enabled?

    platforms = Array(platform).map(&:to_s).reject(&:empty?)
    platform_filter = platforms.empty? ? "" : "AND platform IN {platforms:Array(String)}"
    placeholders = {
      project_id: Integer(project_id),
      start_date: format_date(start_date),
      end_date: format_date(end_date)
    }
    placeholders[:platforms] = platforms unless platforms.empty?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT
          first_day AS event_date,
          platform,
          count() AS first_time_visitors,
          countIf(install_day = first_day) AS new_users
        FROM (
          SELECT
            platform,
            visitor_id,
            toDate(minMerge(first_seen_state)) AS first_day,
            toDate(minIfMerge(install_seen_state)) AS install_day
          FROM visitor_first_seen_daily
          WHERE project_id = {project_id:UInt64}
            #{platform_filter}
          GROUP BY platform, visitor_id
        )
        WHERE first_day >= {start_date:Date}
          AND first_day <= {end_date:Date}
        GROUP BY first_day, platform
        ORDER BY first_day, platform
        #{FIRST_SEEN_QUERY_GUARD}
      SQL
      placeholders: placeholders
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:first_seen_daily, e)
    nil
  end

  # Programming mistakes and already-classified store failures — never a caller's empty shape.
  PROPAGATED_ERRORS = [ArgumentError, Date::Error, Clickhouse::Unavailable, Clickhouse::Stale,
                       RevenueLedger::Unavailable].freeze

  # billing_active_visitors is deliberately NOT here — the dashboard reads it too.
  SOFT_READS = %i[
    billing_active_visitors_per_month_total billing_active_visitors_exact
  ].freeze

  def self.log_query_failure(method, error)
    raise if PROPAGATED_ERRORS.any? { |klass| error.is_a?(klass) }

    Rails.logger.error(
      "ClickhouseReadService##{method}: query failed — #{error.class}: #{error.message}"
    )
    Clickhouse.unavailable!("ClickhouseReadService##{method}", error) unless SOFT_READS.include?(method)
  end
  private_class_method :log_query_failure

  def self.format_date(value)
    Date.parse(value.to_s).strftime('%Y-%m-%d')
  end
  private_class_method :format_date
end
# rubocop:enable Metrics/ModuleLength
