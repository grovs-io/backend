module Segments
  class FirstSeenCondition
    OPS = %w[gte lte].freeze

    def self.build(raw, path:, errors:, cutoff_date:)
      op = raw["op"].to_s
      unless OPS.include?(op)
        errors << { path: "#{path}.op", message: "op must be gte or lte" }
        return nil
      end
      new("op" => op, "value" => Date.iso8601(raw["value"].to_s).iso8601)
    rescue Date::Error
      errors << { path: "#{path}.value", message: "value must be an ISO date (YYYY-MM-DD)" }
      nil
    end

    def initialize(attrs) = @attrs = attrs

    def to_h = { "type" => "first_seen" }.merge(@attrs)
    def negative? = false
    def window = nil

    def rows_sql(env, idx)
      "SELECT visitor_id, toUInt8(#{idx}) AS ci, toUInt64(toUnixTimestamp(minMerge(first_seen_state))) AS n, '' AS s " \
        "FROM visitor_first_seen_daily WHERE project_id = #{Integer(env.project_id)} AND visitor_id != 0 GROUP BY visitor_id"
    end

    def predicate(idx)
      day = Date.iso8601(@attrs["value"]).to_time(:utc)
      bound = @attrs["op"] == "gte" ? ">= #{day.to_i}" : "<= #{(day + 1.day).to_i - 1}"
      "countIf(r.ci = #{idx}) > 0 AND minIf(r.n, r.ci = #{idx}) #{bound}"
    end
  end
end
