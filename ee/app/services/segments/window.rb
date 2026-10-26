module Segments
  module Window
    Bounds = Struct.new(:from, :to, :incomplete)
    FMT = "%Y-%m-%d %H:%M:%S.%3N".freeze

    module_function

    def normalize(raw, cap_days:, cutoff_date:, path:, errors:)
      return fail_with(errors, path, "window is required") unless raw.is_a?(Hash)
      return rolling(raw, cap_days, path, errors) if raw.key?("last_days")

      fixed(raw, cap_days, cutoff_date, path, errors)
    end

    def bounds(window, cutoff_date:, now:)
      if window["last_days"]
        from = (now - window["last_days"].days).utc.beginning_of_day
        to = now
      else
        from = Date.iso8601(window["from"]).to_time(:utc)
        to = [Date.iso8601(window["to"]).to_time(:utc) + 1.day - 0.001, now].min
      end
      cutoff = cutoff_date.to_time(:utc)
      Bounds.new([from, cutoff].max, to, from < cutoff)
    end

    def sql(column, bounds)
      "#{column} >= toDateTime64('#{bounds.from.utc.strftime(FMT)}', 3, 'UTC') AND " \
        "#{column} <= toDateTime64('#{bounds.to.utc.strftime(FMT)}', 3, 'UTC')"
    end

    def rolling(raw, cap_days, path, errors)
      days = Quoting.strict_int(raw["last_days"])
      return { "last_days" => days } if days&.between?(1, cap_days)

      fail_with(errors, path, "last_days must be between 1 and #{cap_days}")
    end

    def fixed(raw, cap_days, cutoff_date, path, errors)
      from = Date.iso8601(raw["from"].to_s)
      to = Date.iso8601(raw["to"].to_s)
      return fail_with(errors, path, "from must be on or before to") if to < from
      return fail_with(errors, path, "window cannot start in the future") if from > Time.now.utc.to_date
      return fail_with(errors, path, "window may span at most #{cap_days} days") if (to - from).to_i >= cap_days
      return fail_with(errors, path, "window starts before the data retention cutoff (#{cutoff_date})") if cutoff_date && from < cutoff_date

      { "from" => from.iso8601, "to" => to.iso8601 }
    rescue Date::Error
      fail_with(errors, path, "from and to must be ISO dates (YYYY-MM-DD)")
    end

    def fail_with(errors, path, message)
      errors << { path: path, message: message }
      nil
    end
  end
end
