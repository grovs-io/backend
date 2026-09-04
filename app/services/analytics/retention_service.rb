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

    # Day 1/7/30 retention rates + sparklines + median churn day.
    # Returns { day_1: Float|nil, day_7: Float|nil, day_30: Float|nil,
    #           sparkline: [...], median_churn_day: Integer|nil }
    def self.summary(project_id, granularity: 'weekly', platform: nil,
                     start_date: nil, end_date: nil, filters: [])
      pid = Integer(project_id)
      platform_filter = platform_where(platform)
      filter_cte, filter_join = visitor_filter_cte(pid, filters)
      date_filter = cohort_date_filter(start_date, end_date)

      all_rates, sparkline = compute_summary(pid, platform_filter, filter_cte, filter_join, date_filter,
                                             start_date: start_date, end_date: end_date)

      rates = {
        day_1: all_rates[1],
        day_7: all_rates[7],
        day_30: all_rates[30]
      }

      # Median churn: first day_n where retention drops below 50%
      median = [1, 3, 7, 14, 30, 60, 90].find { |d| all_rates[d]&.< 50.0 }

      rates.merge(sparkline: sparkline, median_churn_day: median)
    rescue StandardError => e
      log_query_failure(:summary, e)
      { day_1: nil, day_7: nil, day_30: nil, sparkline: [], median_churn_day: nil }
    end

    # --- Private helpers ---

    ALL_DAY_NS = [1, 3, 7, 14, 30, 60, 90].freeze

    # DRY CTE fragments reused across retention queries.
    #
    # user_profiles uses ReplacingMergeTree — FINAL forces in-memory dedup of
    # every row at query time, which gets expensive at scale (1M+ visitors/day).
    # Instead we use min(first_seen) GROUP BY, which:
    #   1. Only reads 2 columns (visitor_id, first_seen) instead of the full row
    #   2. Uses hash aggregation (O(n), constant overhead)
    #   3. Is semantically more correct for retention (earliest install, not latest upsert)
    def self.base_ctes(pid, platform_filter)
      <<~SQL
        WITH visitor_max AS (
          /* Deliberately NOT countable-filtered: "did they come back" is broader than "billable". */
          SELECT visitor_id, max(event_date) AS max_event_date
          FROM visitor_daily
          WHERE project_id = #{pid} #{platform_filter}
          GROUP BY visitor_id
        ), up AS (
          SELECT visitor_id, min(first_seen) AS first_seen
          FROM user_profiles
          WHERE project_id = #{pid} #{platform_filter}
          GROUP BY visitor_id
        )
      SQL
    end
    private_class_method :base_ctes

    # Returns [all_rates_hash, sparkline_array].
    def self.compute_summary(pid, platform_filter, filter_cte = '', filter_join = '', date_filter = '',
                             start_date: nil, end_date: nil)
      # countIf, not countDistinctIf: `up` already has one row per visitor and the joins
      # don't fan out, so it's exact here — and avoids a per-column uniqExact set of every
      # visitor that OOMs the query at ~7M-profile scale.
      rate_columns = ALL_DAY_NS.map do |d|
        <<~COL.squish
          countIf(
            up.first_seen <= now() - INTERVAL #{d} DAY
          ) AS total_#{d},
          countIf(
            up.first_seen <= now() - INTERVAL #{d} DAY
            AND vm.max_event_date >= addDays(toDate(up.first_seen), #{d})
          ) AS retained_#{d}
        COL
      end

      rates_sql = <<~SQL
        #{base_ctes(pid, platform_filter)}#{filter_cte}
        SELECT #{rate_columns.join(",\n")}
        FROM up
        LEFT JOIN visitor_max vm ON vm.visitor_id = up.visitor_id
        #{filter_join}
        WHERE 1=1#{date_filter}
      SQL

      sparkline_start = start_date ? "toDate('#{sanitize_date_value(start_date)}')" : 'toDate(now() - INTERVAL 30 DAY)'
      sparkline_end = end_date ? "toDate('#{sanitize_date_value(end_date)}')" : 'toDate(now() - INTERVAL 1 DAY)'

      sparkline_sql = <<~SQL
        #{base_ctes(pid, platform_filter)}#{filter_cte}
        SELECT
          toDate(up.first_seen) AS cohort_date,
          count() AS total,
          countIf(vm.max_event_date >= addDays(toDate(up.first_seen), 1)) AS retained
        FROM up
        LEFT JOIN visitor_max vm ON vm.visitor_id = up.visitor_id
        #{filter_join}
        WHERE toDate(up.first_seen) >= #{sparkline_start}
          AND toDate(up.first_seen) <= #{sparkline_end}
        GROUP BY cohort_date
        ORDER BY cohort_date
      SQL

      rates_row = with_guard(rates_sql).to_a.first
      sparkline_rows = with_guard(sparkline_sql).to_a

      all_rates = if rates_row
                    ALL_DAY_NS.each_with_object({}) do |d, h|
                      total = rates_row["total_#{d}"].to_i
                      retained = rates_row["retained_#{d}"].to_i
                      h[d] = total.zero? ? nil : (retained.to_f / total * 100).round(1)
                    end
                  else
                    ALL_DAY_NS.index_with { nil }
                  end

      sparkline = sparkline_rows.map do |r|
        total = r['total'].to_i
        retained = r['retained'].to_i
        rate = total.zero? ? nil : (retained.to_f / total * 100).round(1)
        { date: r['cohort_date'].to_s, rate: rate }
      end

      [all_rates, sparkline]
    end
    private_class_method :compute_summary

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

    def self.cohort_date_filter(start_date, end_date)
      return '' if start_date.nil? && end_date.nil?

      clauses = []
      clauses << "toDate(up.first_seen) >= '#{sanitize_date_value(start_date)}'" if start_date
      clauses << "toDate(up.first_seen) <= '#{sanitize_date_value(end_date)}'" if end_date
      " AND #{clauses.join(' AND ')}"
    end
    private_class_method :cohort_date_filter
  end
end
