class VisitorsMetricsQuery
  def initialize(project_ids:, start_date:, end_date:)
    @project_ids = project_ids
    @start_date = start_date.to_date
    @end_date = end_date.to_date
  end

  def call
    # months_difference = (@end_date.year * 12 + @end_date.month) - (@start_date.year * 12 + @start_date.month)
    # months_difference > 2 ? monthly_metrics : daily_metrics
    daily_metrics
  end

  private

  def monthly_metrics
    # Aggregate from ProjectDailyActiveUser using precomputed values
    monthly_counts = ProjectDailyActiveUser
      .where(project_id: @project_ids, event_date: @start_date..@end_date)
      .group("DATE_TRUNC('month', event_date)")
      .sum(:active_users)
      .transform_keys(&:to_date)

    # Build full list of months in the range
    current_month = Date.new(@start_date.year, @start_date.month, 1)
    end_month = Date.new(@end_date.year, @end_date.month, 1)
    all_months = []
    while current_month <= end_month
      all_months << current_month
      current_month >>= 1
    end

    counts = all_months.index_with do |month|
      monthly_counts.fetch(month, 0)
    end

    { metrics_values: counts.transform_keys(&:to_s) }
  end

  def daily_metrics
    daily_counts = ProjectDailyActiveUser
      .where(project_id: @project_ids, event_date: @start_date..@end_date)
      .group(:event_date)
      .sum(:active_users)

    all_dates = (@start_date..@end_date).to_a
    counts = all_dates.index_with do |date|
      daily_counts.fetch(date, 0)
    end

    { metrics_values: counts.transform_keys(&:to_s) }
  end
end