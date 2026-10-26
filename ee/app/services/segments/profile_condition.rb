module Segments
  class ProfileCondition
    OPS = %w[is is_not contains is_set is_not_set].freeze
    PREFIX = "properties.".freeze

    def self.build(raw, path:, errors:, cutoff_date:)
      before = errors.size
      field = raw["field"].to_s
      op = raw["op"].to_s
      key = field.delete_prefix(PREFIX)
      unless field.start_with?(PREFIX) && Analytics::EventsQueryService.valid_property_key?(key)
        errors << { path: "#{path}.field", message: "field must be properties.<key> with a valid key" }
      end
      errors << { path: "#{path}.op", message: "op must be one of #{OPS.join(', ')}" } unless OPS.include?(op)
      values = %w[is_set is_not_set].include?(op) ? nil : Quoting.clean_values(raw["value"], path: "#{path}.value", errors: errors)
      return nil if errors.size > before

      new("field" => field, "op" => op, "value" => values)
    end

    def initialize(attrs) = @attrs = attrs

    def to_h = { "type" => "profile" }.merge(@attrs).compact
    def negative? = %w[is_not is_not_set].include?(@attrs["op"])
    def window = nil

    def rows_sql(env, idx)
      key = @attrs["field"].delete_prefix(PREFIX)
      "SELECT visitor_id, toUInt8(#{idx}) AS ci, toUInt64(1) AS n, '' AS s FROM (" \
        "SELECT visitor_id, argMax(ifNull(CAST(properties.`#{key}` AS Nullable(String)), ''), last_seen) AS val " \
        "FROM user_profiles WHERE project_id = #{Integer(env.project_id)} AND visitor_id != 0 GROUP BY visitor_id) WHERE #{value_clause}"
    end

    def predicate(idx) = "countIf(r.ci = #{idx}) > 0"

    private

    def value_clause
      case @attrs["op"]
      when "is_set", "is_not_set" then "val != ''"
      when "is", "is_not" then Quoting.string_clause("val", "is", @attrs["value"])
      else Quoting.string_clause("val", "contains", @attrs["value"])
      end
    end
  end
end
