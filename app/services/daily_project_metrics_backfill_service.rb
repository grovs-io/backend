class DailyProjectMetricsBackfillService
  class << self
    def call(start_date:, end_date: Date.today)
      start_date = start_date.to_date
      end_date = end_date.to_date

      (start_date..end_date).each do |date|
        DailyProjectMetricsGenerator.call(date)
      end
    end
  end
end
