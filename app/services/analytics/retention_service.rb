# frozen_string_literal: true

module Analytics
  # SQL Interpolation Safety Rules (ClickHouse queries use string interpolation):
  #   - Integers: always wrap with Integer() — raises ArgumentError on bad input
  #   - Strings:  always wrap with sanitize_string() from QueryHelpers
  #   - Dates:    always wrap with sanitize_date_value() from QueryHelpers
  #   - Platform: always use platform_where() helper
  #   - Filters:  always use build_filter_clauses() with an allowed_fields whitelist
  # All public methods rescue StandardError, so ArgumentError/Date::Error → safe empty result.
  module RetentionService
    extend QueryHelpers

    RETENTION_FILTER_FIELDS = %w[
      event_type event_name screen_name platform app_version country city
      device_model os os_version campaign_id link_id session_id visitor_id
      sdk_identifier tracking_source tracking_medium tracking_campaign
    ].freeze

    # Day N = active on exactly day N, among users whose finished day N falls in the range.
    def self.summary(project_id, granularity: 'weekly', platform: nil,
                     start_date: nil, end_date: nil, filters: [], visitor_clause: nil)
      pid = Integer(project_id)
      filter_cte, filter_join = visitor_filter_cte(pid, filters)
      ctx = { pid: pid, platform: platform, filter_cte: filter_cte, filter_join: filter_join,
              start_date: start_date, end_date: end_date, visitor_clause: visitor_clause }

      rates, sizes, median = compute_rates(ctx)
      sparkline = compute_sparkline(ctx)

      {
        day_1: rates[1], day_7: rates[7], day_30: rates[30],
        day_1_users: sizes[1], day_7_users: sizes[7], day_30_users: sizes[30],
        sparkline: sparkline, median_churn_day: median
      }
    rescue StandardError => e
      log_query_failure(:summary, e)
      { day_1: nil, day_7: nil, day_30: nil, day_1_users: 0, day_7_users: 0, day_30_users: 0,
        sparkline: [], median_churn_day: nil }
    end

    ALL_DAY_NS = [1, 3, 7, 14, 30, 60, 90].freeze

    def self.date_sql(value)
      "toDate('#{sanitize_date_value(value)}')"
    end
    private_class_method :date_sql

    # Users whose day N lands in the range and is a finished day.
    def self.eligible_sql(day, start_date, end_date)
      day = Integer(day)
      clauses = ["up.first_date <= today() - #{day + 1}"]
      clauses << "up.first_date >= #{date_sql(start_date)} - #{day}" if start_date
      clauses << "up.first_date <= #{date_sql(end_date)} - #{day}" if end_date
      clauses.join(' AND ')
    end
    private_class_method :eligible_sql

    # min()/GROUP BY instead of FINAL; the cohort comes first so visitor_daily is only read for it.
    def self.base_ctes(ctx, cohort_having, event_range, dates_until)
      pid = ctx[:pid]
      <<~SQL
        WITH up AS (
          SELECT visitor_id, toDate(min(first_seen)) AS first_date
          FROM user_profiles
          WHERE project_id = #{pid} #{platform_where(ctx[:platform])}
          GROUP BY visitor_id
          HAVING #{cohort_having.join(' AND ')}
        ), ret AS (
          /* Deliberately NOT countable-filtered: "did they come back" is broader than "billable". */
          SELECT visitor_id, groupUniqArrayIf(event_date, event_date <= #{dates_until}) AS dates,
                 max(event_date) AS last_date
          FROM visitor_daily
          WHERE project_id = #{pid} #{platform_where(ctx[:platform])}
            AND visitor_id IN (SELECT visitor_id FROM up)
            AND #{event_range.join(' AND ')}
          GROUP BY visitor_id
        )#{ctx[:filter_cte]}
      SQL
    end
    private_class_method :base_ctes

    def self.cohort_from_sql(ctx)
      <<~SQL
        FROM up
        LEFT JOIN ret r ON r.visitor_id = up.visitor_id
        #{ctx[:filter_join]}
      SQL
    end
    private_class_method :cohort_from_sql

    # Returns [{ n => rate|nil }, { n => users }, median churn day|nil].
    def self.compute_rates(ctx)
      start_date = ctx[:start_date]
      end_date = ctx[:end_date]
      # countIf, not countDistinctIf: `up` has one row per visitor and the joins don't fan out.
      columns = ALL_DAY_NS.map do |d|
        elig = eligible_sql(d, start_date, end_date)
        "countIf(#{elig}) AS total_#{d}, " \
          "countIf(#{elig} AND has(r.dates, addDays(up.first_date, #{d}))) AS retained_#{d}, " \
          "countIf(#{elig} AND r.last_date >= addDays(up.first_date, #{d})) AS active_after_#{d}"
      end

      having = ["first_date <= today() - #{ALL_DAY_NS.first + 1}"]
      having << "first_date >= #{date_sql(start_date)} - #{ALL_DAY_NS.last}" if start_date
      having << "first_date <= #{date_sql(end_date)} - #{ALL_DAY_NS.first}" if end_date
      # No upper bound: churn counts any later return, today's included.
      events = [start_date ? "event_date >= #{date_sql(start_date)}" : '1']
      dates_until = end_date ? date_sql(end_date) : 'today()'

      sql = <<~SQL
        #{base_ctes(ctx, having, events, dates_until)}
        SELECT #{columns.join(",\n")}
        #{cohort_from_sql(ctx)}
        #{ctx[:visitor_clause] ? "WHERE #{ctx[:visitor_clause]}" : ''}
      SQL

      row = with_guard(sql).to_a.first || {}
      sizes = ALL_DAY_NS.index_with { |d| row["total_#{d}"].to_i }
      rates = ALL_DAY_NS.index_with { |d| percent(row["retained_#{d}"], sizes[d]) }
      # Churn: first N where under half are active on or after day N.
      median = ALL_DAY_NS.find { |d| percent(row["active_after_#{d}"], sizes[d])&.< 50.0 }
      [rates, sizes, median]
    end
    private_class_method :compute_rates

    def self.percent(part, total)
      total.to_i.zero? ? nil : (part.to_f / total.to_i * 100).round(1)
    end
    private_class_method :percent

    # Day-1 rate per first day in the range; the last 30 days when no range is given.
    def self.compute_sparkline(ctx)
      from = ctx[:start_date] ? date_sql(ctx[:start_date]) : 'today() - 30'
      to = "least(#{ctx[:end_date] ? date_sql(ctx[:end_date]) : 'today()'}, today() - 2)"
      having = ["first_date >= #{from}", "first_date <= #{to}"]
      events = ["event_date >= #{from}", "event_date <= #{to} + 1"]
      dates_until = "#{to} + 1"

      sql = <<~SQL
        #{base_ctes(ctx, having, events, dates_until)}
        SELECT up.first_date AS cohort_date, count() AS total,
               countIf(has(r.dates, addDays(up.first_date, 1))) AS retained
        #{cohort_from_sql(ctx)}
        #{ctx[:visitor_clause] ? "WHERE #{ctx[:visitor_clause]}" : ''}
        GROUP BY cohort_date
        ORDER BY cohort_date
      SQL

      with_guard(sql).to_a.map do |r|
        { date: r['cohort_date'].to_s, rate: percent(r['retained'], r['total']) }
      end
    end
    private_class_method :compute_sparkline

    # Builds a filtered_visitors CTE + INNER JOIN when filters are present.
    # Returns ["", ""] when no filters — zero overhead on unfiltered queries.
    # join_table: alias used in the ON clause (default "up" for user_profiles).
    def self.visitor_filter_cte(pid, filters, join_table: 'up')
      parsed = parse_filters(filters)
      clauses = build_filter_clauses(parsed, allowed_fields: RETENTION_FILTER_FIELDS, table: 'se')
      return ['', ''] if clauses.empty?

      cte = <<~SQL
        , filtered_visitors AS (
            SELECT DISTINCT se.visitor_id
            FROM session_events se
            WHERE se.project_id = #{pid}
              AND #{clauses.join("\n      AND ")}
          )
      SQL
      join = "INNER JOIN filtered_visitors fv ON fv.visitor_id = #{join_table}.visitor_id"
      [cte, join]
    end
    private_class_method :visitor_filter_cte
  end
end
