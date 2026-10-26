# frozen_string_literal: true

module Analytics
  module OverviewStatsService
    extend QueryHelpers

    KEY_METRIC_COUNTERS = %i[
      views link_views opens installs link_driven_installs organic_installs
      reinstalls app_opens referred_users total_users new_users returning_users
    ].freeze

    # Purchase columns stay on PG per Billing::ClickhouseParityCheck::ROLLUP_PARITY (uncovered by the CH event rollup).
    REVENUE_COUNTERS = %i[revenue units_sold cancellations first_time_purchases].freeze

    # PG-only purchase metrics carry no event dimensions, so raw (filtered) mode zeroes and names them.
    UNSUPPORTED_WHEN_FILTERED = %w[revenue units_sold cancellations first_time_purchases arpu arppu].freeze

    # End-to-end staleness bound = rollup rebuild cadence + this TTL.
    def self.cache_ttl
      DashboardCacheTtl.value
    end

    # Single source of truth for cards AND series, rollup-served (link_daily holds only link_id != 0 rows).
    KEY_METRIC_SOURCES = {
      'views' => { table: 'project_daily', event_type: Grovs::Events::VIEW },
      'link_views' => { table: 'link_daily', event_type: Grovs::Events::VIEW },
      'opens' => { table: 'project_daily', event_type: Grovs::Events::OPEN },
      'installs' => { table: 'project_daily', event_type: Grovs::Events::INSTALL },
      'link_driven_installs' => { table: 'link_daily', event_type: Grovs::Events::INSTALL },
      'organic_installs' => :derived,
      'reinstalls' => { table: 'project_daily', event_type: Grovs::Events::REINSTALL },
      'app_opens' => { table: 'project_daily', event_type: Grovs::Events::APP_OPEN },
      'referred_users' => { table: 'project_daily', event_type: Grovs::Events::USER_REFERRED },
      'revenue' => :revenue
    }.freeze

    # Definitions mirror legacy DailyProjectMetrics (installs stay pure — reinstalls reported separately).
    def self.key_metrics(project_id, start_date:, end_date:, platform: nil, filters: nil)
      pid = Integer(project_id)
      sd = sanitize_date(start_date)
      ed = sanitize_date(end_date)
      resolved = OverviewFilters.resolve(filters, platform: platform)
      pf = platform_where(resolved.platform)

      cache_key = "analytics:key_metrics:v3:#{revenue_source}:#{pid}:#{sd}:#{ed}:p=#{resolved.platform}:f=#{resolved.digest}"
      fresh = false
      metrics = UnavailableCache.fetch(cache_key, ttl: cache_ttl) do
        fresh = true
        if resolved.raw?
          compute_key_metrics_raw(pid, sd, ed, pf, resolved.clauses)
        else
          compute_key_metrics(pid, sd, ed, pf, resolved.platform)
        end
      end
      # Degraded (stat-fallback) values cache only briefly (stampede guard, no TTL-long masking).
      if fresh && metrics[:ledger_degraded]
        Rails.cache.write(cache_key, metrics, expires_in: RevenueLedger::DEGRADED_CACHE_TTL)
      end
      metrics.delete(:ledger_degraded)
      { metrics: metrics, unsupported_metrics: resolved.raw? ? UNSUPPORTED_WHEN_FILTERED : [] }
    rescue StandardError => e
      log_query_failure(:key_metrics, e)
      { metrics: (KEY_METRIC_COUNTERS + REVENUE_COUNTERS).index_with { 0 }
                   .merge(returning_rate: 0.0, arpu: 0.0, arppu: 0.0),
        unsupported_metrics: [] }
    end

    def self.compute_key_metrics(pid, start_day, end_day, platform_sql, platform)
      totals = KEY_METRIC_SOURCES.values.filter_map { |src| src[:table] if src.is_a?(Hash) }.uniq
                                 .index_with { |table| totals_by_event_type(table, pid, start_day, end_day, platform_sql) }

      metrics = KEY_METRIC_SOURCES.to_h do |name, src|
        value = src.is_a?(Hash) ? totals[src[:table]].fetch(src[:event_type], 0) : 0
        [name.to_sym, value]
      end
      metrics[:organic_installs] = [metrics[:installs] - metrics[:link_driven_installs], 0].max
      users = classify_users(pid, start_day, end_day, platform_sql)
      metrics.merge!(users)
      metrics.merge!(revenue_metrics(pid, start_day, end_day, platform, users[:total_users]))
      metrics
    end
    private_class_method :compute_key_metrics

    # Raw-events path for filters the rollups do not carry: counters, then user classification.
    def self.compute_key_metrics_raw(pid, start_day, end_day, platform_sql, clauses)
      metrics = OverviewRawEvents.counters(pid, start_day, end_day, clauses)
      metrics[:organic_installs] = [metrics[:installs] - metrics[:link_driven_installs], 0].max
      metrics.merge!(classify_users(pid, start_day, end_day, platform_sql,
                                    visitor_set_sql: OverviewRawEvents.visitor_set(pid, start_day, end_day, clauses)))
      metrics.merge!(revenue: 0, units_sold: 0, cancellations: 0, first_time_purchases: 0, arpu: 0.0, arppu: 0.0)
      metrics
    end
    private_class_method :compute_key_metrics_raw

    # Revenue totals + ARPU/ARPPU. arpu divides by CH total_users; arppu by the PG distinct-paying-device count.
    def self.revenue_metrics(pid, start_day, end_day, platform, total_users)
      range = Date.parse(start_day)..Date.parse(end_day)
      rel = DailyProjectMetric.where(project_id: pid, event_date: range)
      rel = rel.where(platform: platform) if platform
      revenue, units_sold, cancellations, first_time_purchases = rel.pick(
        Arel.sql('COALESCE(SUM(revenue), 0)'),
        Arel.sql('COALESCE(SUM(units_sold), 0)'),
        Arel.sql('COALESCE(SUM(cancellations), 0)'),
        Arel.sql('COALESCE(SUM(first_time_purchases), 0)')
      )&.map(&:to_i) || [0, 0, 0, 0]

      # Ledger when flagged. ALL-OR-NOTHING: any ledger failure keeps every purchase
      # metric stat-sourced (coherent set).
      ledger_totals = nil
      if RevenueLedger.reads_enabled?
        totals = RevenueLedgerQuery.project_totals(pid, start_date: range.begin, end_date: range.end, platform: platform)
        ftp = totals && RevenueLedgerQuery.first_time_purchases(pid, start_date: range.begin, end_date: range.end, platform: platform)
        if totals && ftp
          ledger_totals = totals
          revenue, units_sold, cancellations = totals.values_at(:revenue, :units_sold, :cancellations)
          first_time_purchases = ftp
        end
      end

      # `ledger:` = whether the numerator came from the ledger (no mixed ARPPU populations).
      paying_users = paying_users_for_range(pid, range, platform, ledger: !ledger_totals.nil?)
      {
        revenue: revenue,
        units_sold: units_sold,
        cancellations: cancellations,
        first_time_purchases: first_time_purchases,
        arpu: total_users.positive? ? (revenue.to_f / total_users).round(2) : 0.0,
        arppu: paying_users.positive? ? (revenue.to_f / paying_users).round(2) : 0.0,
        ledger_degraded: RevenueLedger.reads_enabled? && ledger_totals.nil?
      }
    end
    private_class_method :revenue_metrics

    # Distinct paying devices — mirrors legacy DashboardMetrics#unique_paying_users_for_range.
    def self.paying_users_for_range(pid, range, platform, ledger:)
      rel = PurchaseEvent
            .where(project_id: pid, date: range.begin.beginning_of_day..range.end.end_of_day)
            .where(event_type: [Grovs::Purchases::EVENT_BUY, Grovs::Purchases::EVENT_REFUND_REVERSED])
            .where.not(device_id: nil)
      if ledger
        # processed = the same population revenue counts (ARPPU denominator == numerator).
        rel = rel.where(processed: true)
        rel = rel.where(revenue_platform: platform) if platform
      else
        rel = rel.where('webhook_validated = true OR store = false')
        rel = rel.joins(:device).where(devices: { platform: platform }) if platform
      end
      rel.distinct.count(:device_id)
    end
    private_class_method :paying_users_for_range

    # [{ Date => cents }, degraded]: ledger when flagged; degraded=true only when the
    # flagged ledger read failed and the stat fallback served instead.
    def self.revenue_daily_map(pid, lower, upper, platform)
      degraded = false
      if RevenueLedger.reads_enabled?
        ledger = RevenueLedgerQuery.daily_series(pid, start_date: lower, end_date: upper, platform: platform)
        return [ledger, false] unless ledger.nil?

        degraded = true
      end

      rel = DailyProjectMetric.where(project_id: pid, event_date: lower..upper)
      rel = rel.where(platform: platform) if platform
      [rel.group(:event_date).sum(:revenue), degraded]
    end
    private_class_method :revenue_daily_map

    # Flag flips must not serve cached values from the other revenue source.
    def self.revenue_source
      RevenueLedger.reads_enabled? ? "rl" : "st"
    end
    private_class_method :revenue_source

    def self.totals_by_event_type(table, pid, start_day, end_day, platform_sql)
      rows = with_guard(<<~SQL).to_a
        SELECT event_type, sum(cnt) AS total
        FROM #{table}
        WHERE project_id = #{pid}
          AND event_date >= '#{start_day}'
          AND event_date <= '#{end_day}'
          #{platform_sql}
        GROUP BY event_type
      SQL
      rows.to_h { |r| [r['event_type'], r['total'].to_i] }
    end
    private_class_method :totals_by_event_type

    def self.classify_users(pid, start_day, end_day, platform_sql, visitor_set_sql: nil)
      # Platform scopes the WHOLE classification, and the IN pre-filter bounds the history scan.
      range_cond = "event_date >= '#{start_day}' AND event_date <= '#{end_day}'"
      # Countable types only, as the billing tile, PG and visitor_first_seen_daily all count.
      countable = "AND event_type IN #{ClickhouseRollupRebuildService::COUNTABLE_TYPES_SQL}"
      visitor_set_sql ||= <<~SQL
        SELECT DISTINCT visitor_id
        FROM visitor_daily
        WHERE project_id = #{pid}
          AND visitor_id > 0
          #{countable}
          #{platform_sql}
          AND #{range_cond}
      SQL
      users = with_guard(<<~SQL).first || {}
        SELECT
          count()                                                        AS total_users,
          countIf(first_date < '#{start_day}')                           AS returning_users,
          countIf(first_date >= '#{start_day}' AND range_installs > 0)   AS new_users
        FROM (
          SELECT
            visitor_id,
            min(event_date)                                            AS first_date,
            sumIf(cnt, event_type = '#{Grovs::Events::INSTALL}' AND #{range_cond}) AS range_installs
          FROM visitor_daily
          WHERE project_id = #{pid}
            AND visitor_id > 0
            #{countable}
            #{platform_sql}
            AND visitor_id IN (#{visitor_set_sql})
          GROUP BY visitor_id
        )
      SQL

      total_users = users['total_users'].to_i
      returning = users['returning_users'].to_i
      {
        total_users: total_users,
        new_users: users['new_users'].to_i,
        returning_users: returning,
        returning_rate: total_users.zero? ? 0.0 : (returning.to_f / total_users).round(4)
      }
    end
    private_class_method :classify_users

    # Time series for one key metric, zero-filled over range-relative windows (date = window start).
    def self.key_metric_series(project_id, metric:, start_date:, end_date:, platform: nil,
                               filters: nil, granularity: 'day')
      src = KEY_METRIC_SOURCES[metric.to_s]
      return { metric: metric.to_s, points: [] } unless src

      pid = Integer(project_id)
      start_day = sanitize_date(start_date)
      end_day = sanitize_date(end_date)
      granularity = TimeBuckets::GRANULARITIES.include?(granularity.to_s) ? granularity.to_s : 'day'
      resolved = OverviewFilters.resolve(filters, platform: platform)
      return { metric: metric.to_s, points: [], unsupported: true } if src == :revenue && resolved.raw?

      platform_sql = platform_where(resolved.platform)

      cache_key = "analytics:key_metric_series:v4:#{revenue_source}:#{pid}:#{metric}:#{start_day}:#{end_day}" \
                  ":p=#{resolved.platform}:f=#{resolved.digest}:g=#{granularity}"
      fresh = false
      degraded = false
      points = Rails.cache.fetch(cache_key, expires_in: cache_ttl) do
        fresh = true
        by_day, degraded = series_by_day(src, metric.to_s, pid, start_day, end_day, resolved, platform_sql)
        TimeBuckets.sum_by_window(by_day, TimeBuckets.windows(start_day, end_day, granularity))
      end
      Rails.cache.write(cache_key, points, expires_in: RevenueLedger::DEGRADED_CACHE_TTL) if fresh && degraded
      { metric: metric.to_s, points: points }
    rescue StandardError => e
      log_query_failure(:key_metric_series, e)
      { metric: metric.to_s, points: [] }
    end

    # [{ 'YYYY-MM-DD' => value }, ledger_degraded]; revenue is USD cents.
    def self.series_by_day(src, metric, pid, start_day, end_day, resolved, platform_sql)
      if src == :revenue
        map, degraded = revenue_daily_map(pid, Date.parse(start_day), Date.parse(end_day), resolved.platform)
        [map.to_h { |date, cents| [date.to_date.to_s, cents.to_i] }, degraded]
      elsif resolved.raw?
        [OverviewRawEvents.metric_by_day(metric, pid, start_day, end_day, resolved.clauses), false]
      else
        [rollup_metric_by_day(src, pid, start_day, end_day, platform_sql), false]
      end
    end
    private_class_method :series_by_day

    def self.rollup_metric_by_day(src, pid, start_day, end_day, platform_sql)
      if src == :derived
        installs = daily_counts('project_daily', Grovs::Events::INSTALL, pid, start_day, end_day, platform_sql)
        link = daily_counts('link_daily', Grovs::Events::INSTALL, pid, start_day, end_day, platform_sql)
        installs.to_h { |day, value| [day, [value - link.fetch(day, 0), 0].max] }
      else
        daily_counts(src[:table], src[:event_type], pid, start_day, end_day, platform_sql)
      end
    end
    private_class_method :rollup_metric_by_day

    def self.daily_counts(table, event_type, pid, start_day, end_day, platform_sql)
      rows = with_guard(<<~SQL).to_a
        SELECT event_date, sum(cnt) AS value
        FROM #{table}
        WHERE project_id = #{pid}
          AND event_date >= '#{start_day}'
          AND event_date <= '#{end_day}'
          AND event_type = '#{event_type}'
          #{platform_sql}
        GROUP BY event_date
        ORDER BY event_date
      SQL
      rows.to_h { |r| [r['event_date'].to_s[0..9], r['value'].to_i] }
    end
    private_class_method :daily_counts

    # Top versions grouped by platform.
    # Returns { platforms: { "ios" => [{version, users}], ... } }
    def self.versions(project_id, start_date:, end_date:, platform: nil)
      pid = Integer(project_id)
      sd = sanitize_date(start_date)
      ed = sanitize_date(end_date)

      rows = if Clickhouse.analytics_rollups_read_enabled?
               ClickhouseReadService.project_version_daily_stats(
                 pid,
                 start_date: sd,
                 end_date: ed,
                 platform: platform,
                 limit_per_platform: 10
               ).to_a
             else
               raw_version_rows(pid, sd, ed, platform)
             end

      platforms = {}
      rows.each do |r|
        plat = r['platform'].to_s
        platforms[plat] ||= []
        platforms[plat] << { version: r['version'], users: r['users'].to_i }
      end

      platforms.each_value do |entries|
        total = entries.sum { |e| e[:users] }
        entries.each { |e| e[:percent] = safe_percent(e[:users], total) }
      end

      { platforms: platforms }
    rescue StandardError => e
      log_query_failure(:versions, e)
      { platforms: {} }
    end

    # New users + revenue per window with previous-period values; raw mode zeroes revenue.
    def self.user_trends(project_id, start_date:, end_date:, platform: nil, cutoff: nil,
                         filters: nil, granularity: 'day')
      pid = Integer(project_id)
      sd = sanitize_date(start_date)
      ed = sanitize_date(end_date)
      cutoff ||= ::Analytics::RetentionPolicy.cutoff_for(pid) || Date.current
      granularity = TimeBuckets::GRANULARITIES.include?(granularity.to_s) ? granularity.to_s : 'day'
      resolved = OverviewFilters.resolve(filters, platform: platform)
      cache_key = "analytics:user_trends:v3:#{revenue_source}:#{pid}:#{sd}:#{ed}" \
                  ":p=#{resolved.platform}:f=#{resolved.digest}:g=#{granularity}:cutoff=#{cutoff}"

      fresh = false
      result = Rails.cache.fetch(cache_key, expires_in: cache_ttl) do
        fresh = true
        compute_user_trends(pid, sd, ed, resolved, cutoff, granularity)
      end
      # Degraded (stat-fallback) values cache only briefly (stampede guard, no TTL-long masking).
      if fresh && result[:ledger_degraded]
        Rails.cache.write(cache_key, result, expires_in: RevenueLedger::DEGRADED_CACHE_TTL)
      end
      result.delete(:ledger_degraded)
      result
    rescue StandardError => e
      log_query_failure(:user_trends, e)
      { points: [] }
    end

    def self.compute_user_trends(pid, start_day, end_day, resolved, cutoff, granularity)
      platform = resolved.platform
      platform_filter = platform_where(platform)

      start_d = Date.parse(start_day)
      end_d = Date.parse(end_day)
      duration = (end_d - start_d).to_i
      prev_sd = (start_d - duration - 1).strftime('%Y-%m-%d')
      prev_ed = (start_d - 1).strftime('%Y-%m-%d')
      prev_start_d = Date.parse(prev_sd)

      # Floor the previous-period lower bound to the retention cutoff; fail closed if unresolved.
      query_lower_sd = cutoff > prev_start_d ? cutoff.strftime('%Y-%m-%d') : prev_sd
      current_query_sd = cutoff > start_d ? cutoff.strftime('%Y-%m-%d') : start_day
      rev_lower_d = cutoff > prev_start_d ? cutoff : prev_start_d

      # Raw mode: the candidate visitor set comes from filter-matching events over both periods.
      visitor_set_sql = resolved.raw? ? OverviewRawEvents.visitor_set(pid, query_lower_sd, end_day, resolved.clauses) : nil

      current_map, prev_map = daily_new_users(
        pid,
        current_start: current_query_sd,
        current_end: end_day,
        previous_start: query_lower_sd,
        previous_end: prev_ed,
        platform_filter: platform_filter,
        visitor_set_sql: visitor_set_sql
      )

      # Build previous period lookup keyed by offset
      prev_by_offset = {}
      prev_map.each do |date_str, new_users|
        offset = (Date.parse(date_str) - prev_start_d).to_i
        prev_by_offset[offset] = new_users
      end

      # Net daily revenue (USD cents) over current + previous span, same platform filter.
      current_rev = {}
      prev_rev_by_offset = {}
      # Purchase rows carry no event dimensions, so raw mode reports 0 revenue.
      rev_map, rev_degraded = resolved.raw? ? [{}, false] : revenue_daily_map(pid, rev_lower_d, end_d, platform)
      rev_map.each do |date, cents|
        date_str = date.strftime('%Y-%m-%d')
        if date_str >= start_day
          current_rev[date_str] = cents.to_i
        else
          prev_rev_by_offset[(date - prev_start_d).to_i] = cents.to_i
        end
      end

      # Zip current with previous
      points = (start_d..end_d).map do |date|
        offset = (date - start_d).to_i
        ds = date.strftime('%Y-%m-%d')
        {
          date: ds,
          new_users: current_map[ds] || 0,
          previous_new_users: prev_by_offset[offset] || 0,
          # Backward-compatible aliases for dashboards deployed before the
          # explicit new_users response fields.
          users: current_map[ds] || 0,
          previous_users: prev_by_offset[offset] || 0,
          revenue_usd_cents: current_rev[ds] || 0,
          previous_revenue_usd_cents: prev_rev_by_offset[offset] || 0
        }
      end

      { points: bucket_trend_points(points, start_d, end_d, granularity), ledger_degraded: rev_degraded }
    end
    private_class_method :compute_user_trends

    TREND_SUM_KEYS = %i[new_users previous_new_users users previous_users
                        revenue_usd_cents previous_revenue_usd_cents].freeze

    def self.bucket_trend_points(points, start_d, end_d, granularity)
      return points if granularity == 'day'

      by_date = points.index_by { |p| p[:date] }
      TimeBuckets.windows(start_d, end_d, granularity).map do |from, to|
        days = (from..to).filter_map { |d| by_date[d.strftime('%Y-%m-%d')] }
        TREND_SUM_KEYS.index_with { |k| days.sum { |p| p[k] } }.merge(date: from.strftime('%Y-%m-%d'))
      end
    end
    private_class_method :bucket_trend_points

    # Same rows, filter and classification as the key-metrics card — a wider population here
    # moves first_date earlier and drops visitors the tile counts as new.
    def self.daily_new_users(pid, current_start:, current_end:, previous_start:, previous_end:,
                             platform_filter:, visitor_set_sql: nil)
      previous_valid = previous_start <= previous_end
      active_start = [current_start, (previous_valid ? previous_start : current_start)].min
      countable = "AND event_type IN #{ClickhouseRollupRebuildService::COUNTABLE_TYPES_SQL}"
      current_cond = "event_date >= '#{current_start}' AND event_date <= '#{current_end}'"
      previous_cond = if previous_valid
                        "event_date >= '#{previous_start}' AND event_date <= '#{previous_end}'"
                      else
                        '0'
                      end
      visitor_set_sql ||= <<~SQL
        SELECT DISTINCT visitor_id
        FROM visitor_daily
        WHERE project_id = #{pid}
          AND visitor_id > 0
          #{countable}
          #{platform_filter}
          AND event_date >= '#{active_start}'
          AND event_date <= '#{current_end}'
      SQL

      rows = with_guard(<<~SQL).to_a
        SELECT
          first_date AS event_date,
          countIf(first_date >= '#{current_start}' AND first_date <= '#{current_end}' AND current_installs > 0) AS new_users,
          countIf(#{previous_valid ? "first_date >= '#{previous_start}' AND first_date <= '#{previous_end}'" : '0'} AND previous_installs > 0) AS previous_new_users
        FROM (
          SELECT
            visitor_id,
            min(event_date) AS first_date,
            sumIf(cnt, event_type = '#{Grovs::Events::INSTALL}' AND #{current_cond}) AS current_installs,
            sumIf(cnt, event_type = '#{Grovs::Events::INSTALL}' AND #{previous_cond}) AS previous_installs
          FROM visitor_daily
          WHERE project_id = #{pid}
            AND visitor_id > 0
            #{countable}
            #{platform_filter}
            AND visitor_id IN (#{visitor_set_sql})
          GROUP BY visitor_id
        )
        WHERE (first_date >= '#{current_start}' AND first_date <= '#{current_end}')
           OR (#{previous_valid ? "first_date >= '#{previous_start}' AND first_date <= '#{previous_end}'" : '0'})
        GROUP BY first_date
        ORDER BY first_date
      SQL

      current = {}
      previous = {}
      rows.each do |row|
        date = row['event_date'].to_s[0..9]
        current[date] = row['new_users'].to_i if date >= current_start && date <= current_end
        if previous_valid && date >= previous_start && date <= previous_end
          previous[date] = row['previous_new_users'].to_i
        end
      end
      [current, previous]
    end
    private_class_method :daily_new_users

    # { sources:, total: } via attribution flag (own, per-visitor math) → CH rollup → raw CH events.
    def self.sources_breakdown(project_id, start_date:, end_date:, platform: nil, attribution_model: :install)
      pid = Integer(project_id)
      sd = sanitize_date(start_date)
      ed = sanitize_date(end_date)

      rows = if Clickhouse.attribution_read_enabled?
               ClickhouseAttributionReadService.source_breakdown(
                 pid, start_date: sd, end_date: ed, model: attribution_model
               ).to_a
             elsif Clickhouse.analytics_rollups_read_enabled?
               ClickhouseReadService.project_source_daily_stats(
                 pid,
                 start_date: sd,
                 end_date: ed,
                 platform: platform
               ).to_a
             else
               raw_source_rows(pid, sd, ed, platform)
             end

      sources = rows.map do |r|
        { name: display_source_name(r['source']), value: r['visitors'].to_i }
      end
      total = sources.sum { |s| s[:value] }

      { sources: sources, total: total }
    rescue StandardError => e
      log_query_failure(:sources_breakdown, e)
      { sources: [], total: 0 }
    end

    # Version distribution with release dates and platform breakdown.
    # Returns { entries: [{version, release_date, platforms: {}, total}] }
    def self.version_distribution(project_id, start_date:, end_date:, platform: nil, limit: 10, project: nil)
      pid = Integer(project_id)
      sd = sanitize_date(start_date)
      ed = sanitize_date(end_date)
      lim = Integer(limit)

      count_rows, release_map = if Clickhouse.analytics_rollups_read_enabled?
                                  rows = ClickhouseReadService.project_version_distribution_stats(
                                    pid,
                                    start_date: sd,
                                    end_date: ed,
                                    platform: platform,
                                    limit: lim
                                  ).to_a
                                  [rows, fetch_release_dates_from_rollup(pid, rows.map { |r| r['version'] }.uniq)]
                                else
                                  raw_version_distribution_rows(pid, sd, ed, platform, lim)
                                end

      version_data = {}
      count_rows.each do |r|
        ver = r['version']
        version_data[ver] ||= { platforms: {}, total: 0 }
        users = r['users'].to_i
        version_data[ver][:platforms][r['platform'].to_s] = users
        version_data[ver][:total] += users
      end

      entries = version_data.map do |ver, data|
        { version: ver, release_date: release_map[ver], platforms: data[:platforms], total: data[:total] }
      end
      entries.sort_by! { |e| -e[:total] }

      { entries: entries }
    rescue StandardError => e
      log_query_failure(:version_distribution, e)
      { entries: [] }
    end

    # --- Private helpers ---

    # Fetch release dates for the given versions, using Rails.cache to avoid
    # full-table scans. Release dates are immutable (first-seen never changes),
    # so a 24h TTL is safe.
    RELEASE_DATE_TTL = 24.hours

    def self.raw_version_rows(pid, start_day, end_day, platform)
      pf = platform_where(platform)

      with_guard(<<~SQL).to_a
        SELECT platform, version, users
        FROM (
          SELECT
            platform,
            if(app_version = '', 'Unknown', app_version) AS version,
            uniq(visitor_id) AS users,
            row_number() OVER (PARTITION BY platform ORDER BY users DESC) AS rn
          FROM events
          WHERE project_id = #{pid}
            AND toDate(created_at) >= '#{start_day}'
            AND toDate(created_at) <= '#{end_day}'
            #{pf}
          GROUP BY platform, version
        )
        WHERE rn <= 10
        ORDER BY platform, users DESC
      SQL
    end
    private_class_method :raw_version_rows

    def self.raw_source_rows(pid, start_day, end_day, platform)
      pf = platform_where(platform)

      with_guard(<<~SQL).to_a
        SELECT
          #{source_type_expr} AS source,
          uniq(visitor_id) AS visitors
        FROM events
        WHERE project_id = #{pid}
          AND toDate(created_at) >= '#{start_day}'
          AND toDate(created_at) <= '#{end_day}'
          #{pf}
        GROUP BY source
        ORDER BY visitors DESC
      SQL
    end
    private_class_method :raw_source_rows

    def self.raw_version_distribution_rows(pid, start_day, end_day, platform, limit)
      pf = platform_where(platform)

      rows = with_guard(<<~SQL).to_a
        WITH top_versions AS (
          SELECT if(app_version = '', 'Unknown', app_version) AS version
          FROM events
          WHERE project_id = #{pid}
            AND toDate(created_at) >= '#{start_day}'
            AND toDate(created_at) <= '#{end_day}'
            #{pf}
          GROUP BY version
          ORDER BY uniq(visitor_id) DESC, version
          LIMIT #{limit}
        )
        SELECT
          if(app_version = '', 'Unknown', app_version) AS version,
          platform,
          uniq(visitor_id) AS users
        FROM events
        WHERE project_id = #{pid}
          AND toDate(created_at) >= '#{start_day}'
          AND toDate(created_at) <= '#{end_day}'
          AND if(app_version = '', 'Unknown', app_version) IN (SELECT version FROM top_versions)
          #{pf}
        GROUP BY version, platform
      SQL

      [rows, fetch_release_dates_from_events(pid, rows.map { |r| r['version'] }.uniq)]
    end
    private_class_method :raw_version_distribution_rows

    # Release dates are version metadata (for versions already in the gated result
    # set), not event data — intentionally not retention-clamped.
    def self.fetch_release_dates_from_rollup(pid, versions)
      cached_release_dates(pid, versions, source: 'ch') do |uncached|
        ClickhouseReadService.project_version_release_dates(pid, uncached).to_a
      end
    end
    private_class_method :fetch_release_dates_from_rollup

    def self.fetch_release_dates_from_events(pid, versions)
      cached_release_dates(pid, versions, source: 'ev') do |uncached|
        escaped = uncached.map { |v| "'#{sanitize_string(v)}'" }.join(', ')
        with_guard(<<~SQL).to_a
          SELECT if(app_version = '', 'Unknown', app_version) AS version,
                 min(toDate(created_at)) AS release_date
          FROM events
          WHERE project_id = #{pid}
            AND if(app_version = '', 'Unknown', app_version) IN (#{escaped})
          GROUP BY version
        SQL
      end
    end
    private_class_method :fetch_release_dates_from_events

    # `source` segments the key so a flag flip never serves the other source's release dates.
    def self.cached_release_dates(pid, versions, source:)
      return {} if versions.empty?

      result = {}
      uncached = []

      versions.each do |v|
        cached = Rails.cache.read("analytics:release_date:#{source}:#{pid}:#{v}")
        if cached
          result[v] = cached
        else
          uncached << v
        end
      end

      if uncached.any?
        rows = yield uncached

        rows.each do |r|
          date_str = r['release_date'].to_s
          result[r['version']] = date_str
          Rails.cache.write("analytics:release_date:#{source}:#{pid}:#{r['version']}", date_str,
                            expires_in: RELEASE_DATE_TTL)
        end
      end

      result
    end
    private_class_method :cached_release_dates

  end
end
