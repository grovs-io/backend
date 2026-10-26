# frozen_string_literal: true

module Analytics
  # Range-relative windows anchored at start_date so equal-length ranges give equal bucket counts.
  module TimeBuckets
    GRANULARITIES = %w[day week month].freeze

    # [[from, to], ...] covering start..end inclusive, keyed by window start.
    def self.windows(start_date, end_date, granularity)
      sd = start_date.to_date
      ed = end_date.to_date
      return [] if sd > ed
      return (sd..ed).map { |d| [d, d] } if granularity.to_s == 'day'

      step = granularity.to_s == 'month' ? ->(i) { sd >> i } : ->(i) { sd + (7 * i) }
      out = []
      i = 0
      loop do
        from = step.call(i)
        break if from > ed

        to = [step.call(i + 1) - 1, ed].min
        out << [from, to]
        i += 1
      end
      out
    end

    # by_day: { 'YYYY-MM-DD' => Integer }. Zero-filled.
    def self.sum_by_window(by_day, windows)
      windows.map do |from, to|
        { date: from.to_s, value: (from..to).sum { |d| by_day.fetch(d.to_s, 0) } }
      end
    end
  end
end
