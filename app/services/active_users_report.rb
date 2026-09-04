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

  # CH rollup when enabled (nil → PG fallback), PG otherwise
  def fetch_daily_distinct_visitors
    if Clickhouse.analytics_rollups_read_enabled?
      series = clickhouse_series(:day)
      return series unless series.nil?
    end
    pg_daily_distinct_visitors
  end

  def fetch_monthly_distinct_visitors
    if Clickhouse.analytics_rollups_read_enabled?
      series = clickhouse_series(:month)
      return series unless series.nil?
    end
    pg_monthly_distinct_visitors
  end

  # One read per month: a whole-range daily read holds a uniqExact state per bucket and OOMs.
  def clickhouse_series(grouping)
    month_windows.each_with_object({}) do |(from, to), merged|
      series = ClickhouseReadService.active_visitors_series(
        @project_ids, start_date: from, end_date: to, grouping: grouping
      )
      return nil if series.nil?

      merged.merge!(series)
    end
  end

  def month_windows
    @month_windows ||= begin
      windows = []
      cursor = @start_date
      while cursor <= @end_date
        month_end = cursor.end_of_month
        windows << [cursor, [month_end, @end_date].min]
        cursor = month_end + 1
      end
      windows
    end
  end

  # COUNT(DISTINCT visitor_id) per day in range
  def pg_daily_distinct_visitors
    month_windows.each_with_object({}) { |(from, to), merged| merged.merge!(pg_daily_window(from, to)) }
  end

  def pg_daily_window(from, to)
    rows = VisitorDailyStatistic
      .where(project_id: @project_ids, event_date: from..to)
      .where.not(visitor_id: nil)
      .group(:event_date)
      .pluck(:event_date, Arel.sql("COUNT(DISTINCT visitor_id)"))

    rows.to_h.transform_keys!(&:to_date)
  end

  # COUNT(DISTINCT visitor_id) per (partial) month in range
  def pg_monthly_distinct_visitors
    month_windows.each_with_object({}) { |(from, to), merged| merged.merge!(pg_monthly_window(from, to)) }
  end

  def pg_monthly_window(from, to)
    if ActiveRecord::Base.with_connection(&:adapter_name).downcase.include?("mysql")
      rows = VisitorDailyStatistic
        .where(project_id: @project_ids, event_date: from..to)
        .where.not(visitor_id: nil)
        .group(Arel.sql("DATE_FORMAT(event_date, '%Y-%m')"))
        .pluck(Arel.sql("DATE_FORMAT(event_date, '%Y-%m')"), Arel.sql("COUNT(DISTINCT visitor_id)"))
      rows.to_h
    else
      rows = VisitorDailyStatistic
        .where(project_id: @project_ids, event_date: from..to)
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

      csv << ["Range", "#{@start_date} to #{@end_date}"]

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