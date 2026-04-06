class DashboardMetrics
  class << self
    def call(project_id:, start_time:, end_time:, platform: nil)
      start_time = start_time.to_date
      end_time   = end_time.to_date
      platform   = normalize_platform(platform)

      cache_key = "dashboard_metrics:#{project_id}:#{start_time}:#{end_time}:#{platform&.then { Array(_1).sort.join(',') } || 'all'}"
      Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
        period_len = (end_time - start_time).to_i + 1
        prev_start = start_time - period_len
        prev_end   = start_time - 1.day

        {
          current:  metrics_for_range(project_id, start_time, end_time, platform),
          previous: metrics_for_range(project_id, prev_start, prev_end, platform)
        }
      end
    end

    private

    def metrics_for_range(project_id, range_start, range_end, platform)
      rel = DailyProjectMetric
              .where(project_id: project_id, event_date: range_start..range_end)
      rel = rel.where(platform: platform) if platform

      values = rel.pick(
        Arel.sql('COALESCE(SUM(views), 0)'),
        Arel.sql('COALESCE(SUM(installs), 0)'),
        Arel.sql('COALESCE(SUM(reinstalls), 0)'),
        Arel.sql('COALESCE(SUM(opens), 0)'),
        Arel.sql('COALESCE(SUM(app_opens), 0)'),
        Arel.sql('COALESCE(SUM(link_views), 0)'),
        Arel.sql('COALESCE(SUM(referred_users), 0)'),
        Arel.sql('COALESCE(SUM(organic_users), 0)'),
        Arel.sql('COALESCE(SUM(new_users), 0)'),
        Arel.sql('COALESCE(SUM(revenue), 0)'),
        Arel.sql('COALESCE(SUM(units_sold), 0)'),
        Arel.sql('COALESCE(SUM(cancellations), 0)'),
        Arel.sql('COALESCE(SUM(first_time_purchases), 0)'),
        Arel.sql('COALESCE(SUM(first_time_visitors), 0)')
      ) || Array.new(14, 0)

      views, installs, reinstalls, opens, app_opens,
        link_views, referred_users,
        organic_users, new_users,
        revenue, units_sold, cancellations, first_time_purchases,
        first_time_visitors = values.map!(&:to_i)

      total_users      = unique_visitors_for_range(project_id, range_start, range_end, platform)
      returning_users  = [total_users - first_time_visitors, 0].max
      returning_rate   = total_users.zero? ? 0.0 : (returning_users.to_f / total_users)

      paying_users  = unique_paying_users_for_range(project_id, range_start, range_end, platform)
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
        arppu:            arppu
      }
    end

    def dau_for_range(project_id, range_start, range_end, platform)
      rel = ProjectDailyActiveUser.where(project_id: project_id, event_date: range_start..range_end)
      rel = rel.where(platform: platform) if platform
      rel.sum(:active_users).to_i
    end

    def unique_visitors_for_range(project_id, range_start, range_end, platform)
      rel = VisitorDailyStatistic.where(project_id: project_id, event_date: range_start..range_end)
      rel = rel.where(platform: platform) if platform
      rel.distinct.count(:visitor_id)
    end

    # Visitors in the range who have NO VDS record before range_start.
    # Uses a constant bound (range_start) instead of per-row correlation (c.event_date)
    # so Postgres can evaluate the NOT EXISTS as a single index lookup per visitor.
    def unique_first_time_visitors_for_range(project_id, range_start, range_end, platform)
      platform_clause = ""
      platforms_array = Array(platform) if platform

      if platform
        placeholders = platforms_array.map { "?" }.join(", ")
        platform_clause = "AND c.platform IN (#{placeholders})"
        binds = [project_id, range_start, range_end, *platforms_array, range_start]
      else
        binds = [project_id, range_start, range_end, range_start]
      end

      sql = ActiveRecord::Base.send(
        :sanitize_sql_array,
        [<<~SQL, *binds]
          SELECT COUNT(DISTINCT c.visitor_id)
          FROM visitor_daily_statistics c
          WHERE c.project_id = ?
            AND c.event_date BETWEEN ? AND ?
            #{platform_clause}
            AND NOT EXISTS (
              SELECT 1 FROM visitor_daily_statistics p
              WHERE p.project_id = c.project_id
                AND p.visitor_id = c.visitor_id
                AND p.event_date < ?
            )
        SQL
      )

      ActiveRecord::Base.with_connection { |conn| conn.exec_query(sql) }.first["count"].to_i
    end

    def unique_paying_users_for_range(project_id, range_start, range_end, platform)
      rel = PurchaseEvent
        .where(project_id: project_id, date: range_start.beginning_of_day..range_end.end_of_day)
        .where("webhook_validated = true OR store = false")
        .where(event_type: [Grovs::Purchases::EVENT_BUY, Grovs::Purchases::EVENT_REFUND_REVERSED])
        .where.not(device_id: nil)
      rel = rel.joins(:device).where(devices: { platform: platform }) if platform
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
