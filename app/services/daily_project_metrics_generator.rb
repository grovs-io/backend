# app/services/daily_project_metrics_generator.rb
class DailyProjectMetricsGenerator
  class << self
    def call(date)
      date = date.to_date
      data = {}

      data[:visitor_stats]   = fetch_visitor_stats(date)
      data[:link_stats]      = fetch_link_stats(date)
      data[:returning_users]      = fetch_returning_users(date)
      new_and_first_time          = fetch_new_users_and_first_time_visitors(date)
      data[:new_users]            = new_and_first_time[:new_users]
      data[:first_time_visitors]  = new_and_first_time[:first_time_visitors]
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

    # Returning users per project+platform:
    # same visitor_id seen before on the SAME project+platform, on an earlier date
    def fetch_returning_users(date)
      current  = VisitorDailyStatistic.arel_table
      previous = current.alias("previous")

      exists_query = Arel::SelectManager.new
        .from(previous)
        .where(previous[:project_id].eq(current[:project_id]))
        .where(previous[:platform].eq(current[:platform]))
        .where(previous[:visitor_id].eq(current[:visitor_id]))
        .where(previous[:event_date].lt(date))
        .project(Arel.sql("1"))

      VisitorDailyStatistic
        .where(event_date: date)
        .where(Arel::Nodes::Exists.new(exists_query))
        .group(:project_id, :platform)
        .pluck(:project_id, :platform, Arel.sql("COUNT(DISTINCT visitor_id)"))
        .each_with_object({}) { |(pid, platform, count), h| h[[pid.to_i, platform]] = count.to_i }
    end

    # Combined query: first-time visitors (no prior VDS record) and new users
    # (first-time + had installs). Single NOT EXISTS scan instead of two.
    def fetch_new_users_and_first_time_visitors(date)
      current  = VisitorDailyStatistic.arel_table
      previous = current.alias("previous")

      exists_query = Arel::SelectManager.new
        .from(previous)
        .where(previous[:project_id].eq(current[:project_id]))
        .where(previous[:platform].eq(current[:platform]))
        .where(previous[:visitor_id].eq(current[:visitor_id]))
        .where(previous[:event_date].lt(date))
        .project(Arel.sql("1"))

      rows = VisitorDailyStatistic
        .where(event_date: date)
        .where(Arel::Nodes::Not.new(Arel::Nodes::Exists.new(exists_query)))
        .group(:project_id, :platform)
        .pluck(
          :project_id,
          :platform,
          Arel.sql("COUNT(DISTINCT visitor_id)"),
          Arel.sql("COUNT(DISTINCT CASE WHEN installs > 0 THEN visitor_id END)")
        )

      result = { new_users: {}, first_time_visitors: {} }
      rows.each do |(pid, platform, first_time, new_users)|
        key = [pid.to_i, platform]
        result[:new_users][key] = new_users.to_i
        result[:first_time_visitors][key] = first_time.to_i
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
