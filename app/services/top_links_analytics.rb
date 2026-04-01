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

  # Fetches top N links by installs, returning { link_id => metrics } in sorted order
  def fetch_top_link_aggregates
    # Only consider non-SDK links for this project
    project_link_ids = Link.joins(:domain)
                           .where(domains: { project_id: @project_id }, sdk_generated: false)
                           .pluck(:id)

    return {} if project_link_ids.empty?

    stats = LinkDailyStatistic
              .where(project_id: @project_id, event_date: @start_time..@end_time, link_id: project_link_ids)

    stats = stats.where(platform: @platform) if @platform.present?

    rows = stats.group(:link_id)
                .order(Arel.sql("SUM(installs) DESC"))
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

    # Use an ordered hash to preserve the sort order
    rows.each_with_object({}) do |(link_id, views, opens, installs, reinstalls, reactivations, time_spent), h|
      h[link_id] = {
        views: views.to_i,
        opens: opens.to_i,
        installs: installs.to_i,
        reinstalls: reinstalls.to_i,
        reactivations: reactivations.to_i,
        time_spent: time_spent.to_i
      }
    end
  end
end