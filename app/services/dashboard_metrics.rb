class DashboardMetrics
  DEGRADED_KEYS = %i[ledger_degraded ch_degraded].freeze

  class << self
    def call(project_id:, start_time:, end_time:, platform: nil, cutoff: :derive)
      start_time = start_time.to_date
      end_time   = end_time.to_date
      platform   = normalize_platform(platform)
      cutoff     = retention_cutoff(project_id) if cutoff == :derive

      # Source mode in the key: flag flips must not serve cached values from the other store
      source = Clickhouse.analytics_rollups_read_enabled? ? "ch" : "pg"
      source += "-rl" if RevenueLedger.reads_enabled?
      scope = platform&.then { Array(_1).sort.join(',') } || 'all'
      cache_key = "dashboard_metrics:v2:#{source}:#{project_id}:#{start_time}:#{end_time}:#{scope}:cutoff=#{cutoff}"
      fresh = false
      payload = UnavailableCache.fetch(cache_key, ttl: cache_ttl) do
        fresh = true
        period_len = (end_time - start_time).to_i + 1
        prev_start = start_time - period_len
        prev_end   = start_time - 1.day

        current = metrics_for_range(project_id, start_time, end_time, platform)
        # Zeroed values read as a delta, so previous_available tells the FE to show none.
        out_of_window = cutoff && prev_start < cutoff
        previous = out_of_window ? zeroed_like(current) : metrics_for_range(project_id, prev_start, prev_end, platform)

        { current: current, previous: previous, previous_available: !out_of_window }
      end
      # Stat-fallback values cache briefly: a full TTL would pin them after CH/ledger recovers.
      degraded = DEGRADED_KEYS.any? { |k| payload[:current][k] || payload[:previous][k] }
      Rails.cache.write(cache_key, payload, expires_in: RevenueLedger::DEGRADED_CACHE_TTL) if fresh && degraded
      DEGRADED_KEYS.each { |k| [payload[:current], payload[:previous]].each { |m| m.delete(k) } }
      payload
    end

    def cache_ttl
      DashboardCacheTtl.value
    end

    private

    def retention_cutoff(project_id)
      return nil unless Clickhouse.analytics_rollups_read_enabled?

      ::Analytics::RetentionPolicy.cutoff_for(project_id)
    end

    # Same keys and numeric types, all zeroed — the FE renders "no comparison".
    def zeroed_like(metrics)
      metrics.transform_values { |value| value.is_a?(Numeric) ? value * 0 : value }
    end

    def metrics_for_range(project_id, range_start, range_end, platform)
      rel = DailyProjectMetric
              .where(project_id: project_id, event_date: range_start..range_end)
      rel = rel.where(platform: platform) if platform

      # Purchase columns stay PG even with the flag on (parity `uncovered`).
      derived = rel.pick(
        Arel.sql('COALESCE(SUM(link_views), 0)'),
        Arel.sql('COALESCE(SUM(referred_users), 0)'),
        Arel.sql('COALESCE(SUM(organic_users), 0)'),
        Arel.sql('COALESCE(SUM(new_users), 0)'),
        Arel.sql('COALESCE(SUM(revenue), 0)'),
        Arel.sql('COALESCE(SUM(units_sold), 0)'),
        Arel.sql('COALESCE(SUM(cancellations), 0)'),
        Arel.sql('COALESCE(SUM(first_time_purchases), 0)'),
        Arel.sql('COALESCE(SUM(first_time_visitors), 0)')
      ) || Array.new(9, 0)

      link_views, referred_users, organic_users, new_users,
        revenue, units_sold, cancellations, first_time_purchases,
        first_time_visitors = derived.map(&:to_i)

      # Revenue never moves to CH: ledger when flagged. ALL-OR-NOTHING — if any
      # ledger read fails, every purchase metric stays stat-sourced (coherent set).
      ledger_totals = nil
      if RevenueLedger.reads_enabled?
        totals = RevenueLedgerQuery.project_totals(
          project_id, start_date: range_start, end_date: range_end, platform: platform
        )
        ftp = totals && RevenueLedgerQuery.first_time_purchases(
          project_id, start_date: range_start, end_date: range_end, platform: platform
        )
        if totals && ftp
          ledger_totals = totals
          revenue, units_sold, cancellations = totals.values_at(:revenue, :units_sold, :cancellations)
          first_time_purchases = ftp
        end
      end

      ch_derived, ch_degraded = derived_from_clickhouse(project_id, range_start, range_end, platform)
      new_users = ch_derived.fetch(:new_users, new_users)
      first_time_visitors = ch_derived.fetch(:first_time_visitors, first_time_visitors)
      organic_users = ch_derived.fetch(:organic_users, organic_users)
      link_views = ch_derived.fetch(:link_views, link_views)
      referred_users = ch_derived.fetch(:referred_users, referred_users)

      countables, countables_degraded =
        countable_metrics_for_range(rel, project_id, range_start, range_end, platform)
      views, opens, installs, reinstalls, app_opens = countables
      ch_degraded ||= countables_degraded

      total_users, visitors_degraded =
        unique_visitors_for_range(project_id, range_start, range_end, platform)
      ch_degraded ||= visitors_degraded
      returning_users  = [total_users - first_time_visitors, 0].max
      returning_rate   = total_users.zero? ? 0.0 : (returning_users.to_f / total_users)

      # `ledger:` tracks whether the NUMERATOR actually came from the ledger, so a
      # transient ledger failure never mixes populations in ARPPU.
      paying_users = unique_paying_users_for_range(project_id, range_start, range_end, platform,
                                                   ledger: !ledger_totals.nil?)
      arpu  = total_users > 0 ? (revenue.to_f / total_users).round(2) : 0.0
      arppu = paying_users > 0 ? (revenue.to_f / paying_users).round(2) : 0.0

      {
        views:            views,
        link_views:       link_views,
        link_driven_installs: installs - organic_users,
        organic_users:    organic_users,
        opens:            opens,
        installs:         installs,
        reinstalls:       reinstalls,
        app_opens:        app_opens,
        new_users:        new_users,
        returning_users:  returning_users,
        returning_rate:   returning_rate,
        referred_users:   referred_users,
        revenue:          revenue,
        units_sold:       units_sold,
        cancellations:    cancellations,
        first_time_purchases: first_time_purchases,
        arpu:             arpu,
        arppu:            arppu,
        ledger_degraded:  RevenueLedger.reads_enabled? && ledger_totals.nil?,
        ch_degraded:      ch_degraded
      }
    end

    # Returns [{ column => CH value } for every reader that answered, ch_degraded].
    def derived_from_clickhouse(project_id, range_start, range_end, platform)
      return [{}, false] unless Clickhouse.analytics_rollups_read_enabled?

      range = { start_date: range_start, end_date: range_end, platform: platform }
      first_seen = first_seen_totals(project_id, range_start, range_end, platform)
      scalars = {
        organic_users: ClickhouseReadService.organic_users_total(project_id, **range),
        link_views: ClickhouseReadService.link_views_total(project_id, **range),
        referred_users: ClickhouseReadService.referred_users_total(project_id, **range)
      }

      values = scalars.compact
      if first_seen
        values[:new_users], values[:first_time_visitors] = first_seen
      end
      [values, first_seen.nil? || scalars.value?(nil)]
    end

    # Returns [[views, opens, installs, reinstalls, app_opens], ch_degraded].
    def countable_metrics_for_range(pg_rel, project_id, range_start, range_end, platform)
      flagged = Clickhouse.analytics_rollups_read_enabled?
      if flagged
        ch = ClickhouseReadService.project_metrics_daily_totals(
          project_id, start_date: range_start, end_date: range_end, platform: platform
        )
        # PG DPM.installs is folded (installs+reinstalls); CH is pure — fold at this seam only
        if ch
          return [[ch[:views], ch[:opens], ch[:installs] + ch[:reinstalls], ch[:reinstalls], ch[:app_opens]], false]
        end
      end

      pg = pg_rel.pick(
        Arel.sql('COALESCE(SUM(views), 0)'),
        Arel.sql('COALESCE(SUM(opens), 0)'),
        Arel.sql('COALESCE(SUM(installs), 0)'),
        Arel.sql('COALESCE(SUM(reinstalls), 0)'),
        Arel.sql('COALESCE(SUM(app_opens), 0)')
      )&.map(&:to_i) || [0, 0, 0, 0, 0]
      [pg, flagged]
    end

    # Returns [total_users, ch_degraded].
    def unique_visitors_for_range(project_id, range_start, range_end, platform)
      flagged = Clickhouse.analytics_rollups_read_enabled?
      if flagged
        ch = if platform
               ClickhouseReadService.unique_visitors_by_platform(
                 project_id, start_date: range_start, end_date: range_end, platforms: Array(platform)
               )
             else
               ClickhouseReadService.billing_active_visitors(
                 [project_id], start_date: range_start, end_date: range_end
               )
             end
        return [ch, false] unless ch.nil?
      end

      rel = VisitorDailyStatistic.where(project_id: project_id, event_date: range_start..range_end)
      rel = rel.where(platform: platform) if platform
      [rel.distinct.count(:visitor_id), flagged]
    end

    # nil on unavailable so the PG pick stays authoritative.
    def first_seen_totals(project_id, range_start, range_end, platform)
      rows = ClickhouseReadService.first_seen_daily(
        project_id, start_date: range_start, end_date: range_end, platform: platform
      )
      return nil if rows.nil?

      [rows.sum { |r| r["new_users"].to_i }, rows.sum { |r| r["first_time_visitors"].to_i }]
    end

    # Visitors in the range who have NO VDS record before range_start.
    # Uses a constant bound (range_start) instead of per-row correlation (c.event_date)
    # so Postgres can evaluate the NOT EXISTS as a single index lookup per visitor.
    def unique_paying_users_for_range(project_id, range_start, range_end, platform, ledger:)
      rel = PurchaseEvent
        .where(project_id: project_id, date: range_start.beginning_of_day..range_end.end_of_day)
        .where(event_type: [Grovs::Purchases::EVENT_BUY, Grovs::Purchases::EVENT_REFUND_REVERSED])
        .where.not(device_id: nil)
      if ledger
        # processed = the same population revenue counts (ARPPU denominator == numerator).
        rel = rel.where(processed: true)
        rel = rel.where(revenue_platform: platform) if platform
      else
        rel = rel.where("webhook_validated = true OR store = false")
        rel = rel.joins(:device).where(devices: { platform: platform }) if platform
      end
      rel.distinct.count(:device_id)
    end

    # Accepts string, array, or nil. Returns nil for empty/blank input.
    def normalize_platform(value)
      return nil if value.blank?
      arr = Array(value).map(&:to_s).reject(&:blank?)
      return nil if arr.empty?
      arr.size == 1 ? arr.first : arr
    end
  end
end
