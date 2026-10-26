module Segments
  class AcquisitionCondition
    ID_FIELDS = %w[link_id campaign_id].freeze
    STRING_FIELDS = %w[tracking_source tracking_medium].freeze
    LOOKBACK_DAYS = Integer(ENV.fetch("SEGMENT_ACQUISITION_LOOKBACK_DAYS", 365))
    INSTALL_TYPES = [Grovs::Events::INSTALL, Grovs::Events::REINSTALL].freeze

    def self.build(raw, path:, errors:, cutoff_date:)
      before = errors.size
      field = raw["field"].to_s
      op = raw["op"].to_s
      ids = ID_FIELDS.include?(field)
      errors << { path: "#{path}.field", message: "field must be one of #{(ID_FIELDS + STRING_FIELDS).join(', ')}" } unless ids || STRING_FIELDS.include?(field)
      allowed = ids ? %w[is is_not] : Quoting::STRING_OPS
      errors << { path: "#{path}.op", message: "op must be one of #{allowed.join(', ')}" } unless allowed.include?(op)
      values = ids ? id_values(raw["value"], "#{path}.value", errors) : Quoting.clean_values(raw["value"], path: "#{path}.value", errors: errors)
      window = build_window(raw["window"], cutoff_date, path, errors)
      return nil if errors.size > before

      new("field" => field, "op" => op, "value" => values, "window" => window)
    end

    def self.build_window(raw_window, cutoff_date, path, errors)
      default_days = LOOKBACK_DAYS
      if raw_window.nil? && cutoff_date
        queryable_days = (Date.current - cutoff_date).to_i
        default_days = [[queryable_days, 1].max, LOOKBACK_DAYS].min
      end
      Window.normalize(raw_window || { "last_days" => default_days }, cap_days: LOOKBACK_DAYS, cutoff_date: cutoff_date,
                                                                        path: "#{path}.window", errors: errors)
    end

    def self.id_values(raw, path, errors)
      list = Array(raw).map { |v| Quoting.strict_int(v) }
      if list.empty? || list.size > Quoting::MAX_VALUES || list.any? { |v| v.nil? || v <= 0 }
        errors << { path: path, message: "value must be 1-#{Quoting::MAX_VALUES} positive integer ids" }
        return nil
      end
      list.uniq.sort
    end

    def initialize(attrs) = @attrs = attrs

    def to_h = { "type" => "acquisition" }.merge(@attrs)
    def negative? = @attrs["op"] == "is_not"
    def window = @attrs["window"]

    def rows_sql(env, idx)
      b = Window.bounds(window, cutoff_date: env.cutoff_date, now: env.now)
      types = INSTALL_TYPES.map { |t| Quoting.literal(t) }.join(", ")
      "SELECT visitor_id, toUInt8(#{idx}) AS ci, toUInt64(1) AS n, '' AS s FROM events " \
        "WHERE project_id = #{Integer(env.project_id)} AND visitor_id != 0 AND #{Window.sql('created_at', b)} " \
        "AND event_type IN (#{types}) AND #{value_clause} GROUP BY visitor_id"
    end

    def predicate(idx) = "countIf(r.ci = #{idx}) > 0"

    private

    def value_clause
      field = @attrs["field"]
      return "#{field} IN (#{@attrs['value'].map { |v| Integer(v) }.join(', ')})" if ID_FIELDS.include?(field)

      Quoting.string_clause(field, negative? ? "is" : @attrs["op"], @attrs["value"])
    end
  end
end
