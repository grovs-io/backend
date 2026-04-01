# app/services/active_users_report.rb
require "csv"

class ActiveUsersReport
  def initialize(project_ids:, start_date:, end_date:)
    @project_ids = Array(project_ids)
    @start_date  = start_date.to_date
    @end_date    = end_date.to_date
    raise ArgumentError, "start_date > end_date" if @start_date > @end_date
  end

  def call
    daily        = fetch_daily_distinct_visitors            # { Date => count }
    filled_daily = zero_fill_days(daily)

    monthly        = fetch_monthly_distinct_visitors        # { "YYYY-MM" => count }
    filled_monthly = zero_fill_months(monthly)

    monthly_total = filled_monthly.values.sum               # dashboard-style total

    build_csv(filled_daily, filled_monthly, monthly_total)
  end

  private

  # COUNT(DISTINCT visitor_id) per day in range
  def fetch_daily_distinct_visitors
    rows = VisitorDailyStatistic
      .where(project_id: @project_ids, event_date: @start_date..@end_date)
      .where.not(visitor_id: nil)
      .group(:event_date)
      .pluck(:event_date, Arel.sql("COUNT(DISTINCT visitor_id)"))

    rows.to_h.transform_keys!(&:to_date)
  end

  # COUNT(DISTINCT visitor_id) per (partial) month in range
  def fetch_monthly_distinct_visitors
    if ActiveRecord::Base.with_connection(&:adapter_name).downcase.include?("mysql")
      rows = VisitorDailyStatistic
        .where(project_id: @project_ids, event_date: @start_date..@end_date)
        .where.not(visitor_id: nil)
        .group(Arel.sql("DATE_FORMAT(event_date, '%Y-%m')"))
        .pluck(Arel.sql("DATE_FORMAT(event_date, '%Y-%m')"), Arel.sql("COUNT(DISTINCT visitor_id)"))
      rows.to_h
    else
      rows = VisitorDailyStatistic
        .where(project_id: @project_ids, event_date: @start_date..@end_date)
        .where.not(visitor_id: nil)
        .group(Arel.sql("date_trunc('month', event_date)"))
        .pluck(Arel.sql("date_trunc('month', event_date)::date"),
               Arel.sql("COUNT(DISTINCT visitor_id)"))

      rows.each_with_object({}) { |(month_start, count), h| h[month_start.strftime("%Y-%m")] = count }
    end
  end

  def zero_fill_days(daily_hash)
    (@start_date..@end_date).index_with { |d| daily_hash[d] || 0 }
  end

  def zero_fill_months(monthly_hash)
    months = []
    m = @start_date.beginning_of_month
    last = @end_date.beginning_of_month
    while m <= last
      months << m.strftime("%Y-%m")
      m = m.next_month
    end
    months.index_with { |k| monthly_hash[k] || 0 }
  end

  def build_csv(filled_daily, filled_monthly, monthly_total)
    CSV.generate(headers: true) do |csv|

      # Totals (dashboard-comparable)
      csv << ["Sum of Monthly Unique Active Users", monthly_total]
      csv << [] # separator

      # Monthly (distinct per month; partial months respected)
      csv << ["Month", "Unique Monthly Active Users"]
      filled_monthly.keys.sort.each { |m| csv << [m, filled_monthly[m]] }

      csv << [] # separator

      # Daily
      csv << ["Date", "Daily Unique Active Users"]
      filled_daily.each { |date, count| csv << [date.strftime("%Y-%m-%d"), count] }
    end
  end
end