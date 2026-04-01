class LinksViewsReportDashboard
  def initialize(project_id:, platform:, start_date:, end_date:)
    @project_id = project_id
    @platform = platform
    @start_date = start_date.to_date
    @end_date = end_date.to_date
  end

  def call
    # Initialize all dates with 0
    daily_counts = (@start_date..@end_date).index_with { 0 }

    # Pull app_opens per day from daily_project_metrics
    results = DailyProjectMetric
      .where(project_id: @project_id, event_date: @start_date..@end_date)

    if @platform.present?
      results = results.where(platform: @platform)
    end

    results = results.group(:event_date).sum(:link_views)

    # Populate actual values into the result
    results.each do |date, views|
      daily_counts[date.to_s] = views.to_i
    end

    daily_counts
  end
end