# app/services/daily_project_metrics_generator.rb
class DailyProjectMetricsGenerator
  class << self
    def call(date)
      date = date.to_date
      data = {}

      data[:visitor_stats]   = fetch_visitor_stats(date)
      data[:link_stats]      = fetch_link_stats(date)
      classification              = fetch_visitor_classification(date)
      data[:returning_users]      = classification[:returning_users]
      data[:new_users]            = classification[:new_users]
      data[:first_time_visitors]  = classification[:first_time_visitors]
      data[:referred_users]       = fetch_referred_users(date)
      data[:revenue_stats]   = fetch_revenue_stats(date)

      persist_metrics(data, date)
    end

    private

    # Sum visitor-side counters per project+platform
    def fetch_visitor_stats(date)
      VisitorDailyStatistic
        .where(event_date: date)
        .group(:project_id, :platform)
        .pluck(
          :project_id,
          :platform,
          Arel.sql("SUM(views)"),
          Arel.sql("SUM(opens)"),
          Arel.sql("SUM(installs)"),
          Arel.sql("SUM(reinstalls)"),
          Arel.sql("SUM(app_opens)")
        )
        .each_with_object({}) do |(project_id, platform, views, opens, installs, reinstalls, app_opens), h|
          h[[project_id, platform]] = {
            views: views.to_i,
            opens: opens.to_i,
            installs: installs.to_i,
            reinstalls: reinstalls.to_i,
            app_opens: app_opens.to_i
          }
        end
    end

    # Link stats per project+platform, if the table has platform; otherwise zeros
    def fetch_link_stats(date)
      LinkDailyStatistic
        .where(event_date: date)
        .group(:project_id, :platform)
        .pluck(
          :project_id,
          :platform,
          Arel.sql("SUM(views)"),
          Arel.sql("SUM(installs)")
        )
        .each_with_object({}) do |(project_id, platform, link_views, link_installs), h|
          h[[project_id, platform]] = {
            link_views: link_views.to_i,
            link_installs: link_installs.to_i
          }
        end
    end

    # Classify visitors active on `date` into returning / first-time / new, in one pass
    # (was two full-day scans computing the same "has a prior record?" predicate twice).
    #   Returning  = same visitor seen earlier on this project+platform
    #   First-time = no prior record for this project+platform+visitor
    #   New        = first-time AND installs > 0 that day
    # AS MATERIALIZED is required: otherwise Postgres inlines `has_prior` and re-runs the
    # correlated EXISTS once per FILTER. COUNT(*) (not COUNT(DISTINCT)) is safe because the
    # unique (project_id, visitor_id, event_date, platform) index gives one row per visitor/day.
    def fetch_visitor_classification(date)
      sql = DailyProjectMetric.sanitize_sql_array([<<~SQL, date, date])
        WITH classified AS MATERIALIZED (
          SELECT v.project_id, v.platform, v.visitor_id, v.installs,
                 EXISTS (
                   SELECT 1 FROM visitor_daily_statistics p
                   WHERE p.project_id = v.project_id
                     AND p.platform   = v.platform
                     AND p.visitor_id = v.visitor_id
                     AND p.event_date < ?::date
                 ) AS has_prior
          FROM visitor_daily_statistics v
          WHERE v.event_date = ?::date
        )
        SELECT project_id, platform,
          COUNT(*) FILTER (WHERE has_prior)                        AS returning_users,
          COUNT(*) FILTER (WHERE NOT has_prior)                    AS first_time_visitors,
          COUNT(*) FILTER (WHERE NOT has_prior AND installs > 0)   AS new_users
        FROM classified
        GROUP BY project_id, platform
      SQL

      result = { returning_users: {}, new_users: {}, first_time_visitors: {} }
      VisitorDailyStatistic.connection.select_all(sql).each do |row|
        key = [row["project_id"].to_i, row["platform"]]
        result[:returning_users][key]     = row["returning_users"].to_i
        result[:first_time_visitors][key] = row["first_time_visitors"].to_i
        result[:new_users][key]           = row["new_users"].to_i
      end
      result
    end

    # Revenue stats from pre-aggregated in_app_product_daily_statistics.
    # Single source of truth: ProcessPurchaseEventJob -> InAppProductEventService
    # populates this table in real-time for every processed purchase event.
    def fetch_revenue_stats(date)
      InAppProductDailyStatistic
        .where(event_date: date)
        .group(:project_id, :platform)
        .having("SUM(revenue) != 0 OR SUM(purchase_events) != 0 OR SUM(canceled_events) != 0")
        .pluck(
          :project_id,
          :platform,
          Arel.sql("SUM(revenue)"),
          Arel.sql("SUM(purchase_events)"),
          Arel.sql("SUM(canceled_events)"),
          Arel.sql("SUM(first_time_purchases)")
        )
        .each_with_object({}) do |(project_id, platform, revenue, units, cancels, first_time), h|
          h[[project_id, platform]] = {
            revenue:              revenue.to_i,
            units_sold:           units.to_i,
            cancellations:        cancels.to_i,
            first_time_purchases: first_time.to_i
          }
        end
    end

    # Referred users per project+platform
    def fetch_referred_users(date)
      VisitorDailyStatistic
        .where(event_date: date)
        .where.not(invited_by_id: nil)
        .group(:project_id, :platform)
        .count
        .transform_keys { |(pid, platform)| [pid, platform] }
    end

    def persist_metrics(data, date)
      keys = [
        data[:visitor_stats].keys,
        data[:link_stats].keys,
        data[:returning_users].keys,
        data[:new_users].keys,
        data[:first_time_visitors].keys,
        data[:referred_users].keys,
        data[:revenue_stats].keys
      ].flatten(1).uniq

      keys.each do |project_id, platform|
        vs = data[:visitor_stats][[project_id, platform]] || {}
        ls = data[:link_stats][[project_id, platform]] || { link_views: 0, link_installs: 0 }
        rs = data[:revenue_stats][[project_id, platform]] || {}

        total_installs = vs[:installs].to_i + vs[:reinstalls].to_i
        link_installs  = ls[:link_installs].to_i
        organic_users  = [total_installs - link_installs, 0].max

        DailyProjectMetric.connection.execute(
          DailyProjectMetric.sanitize_sql_array([
            "INSERT INTO daily_project_metrics (project_id, event_date, platform, views, installs, opens, " \
            "reinstalls, app_opens, link_views, returning_users, referred_users, organic_users, new_users, " \
            "first_time_visitors, revenue, units_sold, cancellations, first_time_purchases, created_at, updated_at) " \
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) " \
            "ON CONFLICT (project_id, event_date, platform) DO UPDATE SET " \
            "views = EXCLUDED.views, installs = EXCLUDED.installs, opens = EXCLUDED.opens, " \
            "reinstalls = EXCLUDED.reinstalls, app_opens = EXCLUDED.app_opens, link_views = EXCLUDED.link_views, " \
            "returning_users = EXCLUDED.returning_users, referred_users = EXCLUDED.referred_users, " \
            "organic_users = EXCLUDED.organic_users, new_users = EXCLUDED.new_users, " \
            "first_time_visitors = EXCLUDED.first_time_visitors, revenue = EXCLUDED.revenue, " \
            "units_sold = EXCLUDED.units_sold, cancellations = EXCLUDED.cancellations, " \
            "first_time_purchases = EXCLUDED.first_time_purchases, updated_at = EXCLUDED.updated_at",
            project_id, date, platform,
            vs[:views].to_i, total_installs, vs[:opens].to_i,
            vs[:reinstalls].to_i, vs[:app_opens].to_i, ls[:link_views].to_i,
            data[:returning_users][[project_id, platform]].to_i,
            data[:referred_users][[project_id, platform]].to_i,
            organic_users,
            data[:new_users][[project_id, platform]].to_i,
            data[:first_time_visitors][[project_id, platform]].to_i,
            rs[:revenue].to_i, rs[:units_sold].to_i, rs[:cancellations].to_i,
            rs[:first_time_purchases].to_i,
            Time.current, Time.current
          ])
        )
      end
    end
  end
end
