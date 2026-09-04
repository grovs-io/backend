class TopLinksAnalytics
  def initialize(project_id:, platform:, start_time:, end_time:, limit: 10)
    @project_id = project_id
    @platform = platform
    @start_time = start_time.to_date
    @end_time = end_time.to_date
    @limit = limit
  end

  def call
    # 1. Find top link IDs from stats first (avoids loading all links into memory)
    top_stats = fetch_top_link_aggregates
    return [] if top_stats.empty?

    # 2. Load only the links we need
    links = Link
              .eager_load(:domain)
              .includes(:custom_redirects)
              .with_attached_image
              .where(id: top_stats.keys)
              .index_by(&:id)

    # 3. Merge link data with stats, preserving sort order
    top_stats.map do |link_id, metrics|
      link = links[link_id]
      {
        **(link ? LinkSerializer.serialize(link) : {}),
        **metrics
      }
    end
  end

  private

  # Fetches top N links by installs, returning { link_id => metrics } in sorted order.
  # sdk_generated:false stays on PG (bounded set); the heavy date-range aggregation
  # goes to the CH link_metrics_daily rollup when the flag is on.
  def fetch_top_link_aggregates
    project_link_ids = Link.joins(:domain)
                           .where(domains: { project_id: @project_id }, sdk_generated: false)
                           .pluck(:id)

    return {} if project_link_ids.empty?

    if Clickhouse.analytics_rollups_read_enabled?
      ch_top_link_aggregates(project_link_ids) || pg_top_link_aggregates(project_link_ids)
    else
      pg_top_link_aggregates(project_link_ids)
    end
  end

  def pg_top_link_aggregates(project_link_ids)
    stats = LinkDailyStatistic
              .where(project_id: @project_id, event_date: @start_time..@end_time, link_id: project_link_ids)

    stats = stats.where(platform: @platform) if @platform.present?

    rows = stats.group(:link_id)
                # link_id ASC tiebreak matches CH so ties return the same set at the LIMIT.
                .order(Arel.sql("SUM(installs) DESC, link_id ASC"))
                .limit(@limit)
                .pluck(
                  :link_id,
                  Arel.sql("SUM(views)"),
                  Arel.sql("SUM(opens)"),
                  Arel.sql("SUM(installs)"),
                  Arel.sql("SUM(reinstalls)"),
                  Arel.sql("SUM(reactivations)"),
                  Arel.sql("SUM(time_spent)")
                )

    rows.each_with_object({}) do |(link_id, views, opens, installs, reinstalls, reactivations, time_spent), h|
      h[link_id] = metrics_hash(views, opens, installs, reinstalls, reactivations, time_spent)
    end
  end

  # nil when CH is unavailable → caller falls back to PG.
  def ch_top_link_aggregates(project_link_ids)
    rows = ClickhouseReadService.top_link_metrics(
      @project_id, link_ids: project_link_ids,
      start_date: @start_time, end_date: @end_time,
      platform: @platform.presence, limit: @limit
    )
    return nil if rows.nil?

    rows.each_with_object({}) do |r, h|
      h[r["link_id"].to_i] = metrics_hash(
        r["views"], r["opens"], r["installs"], r["reinstalls"], r["reactivations"], r["time_spent"]
      )
    end
  end

  def metrics_hash(views, opens, installs, reinstalls, reactivations, time_spent)
    {
      views: views.to_i,
      opens: opens.to_i,
      installs: installs.to_i,
      reinstalls: reinstalls.to_i,
      reactivations: reactivations.to_i,
      time_spent: time_spent.to_i
    }
  end
end