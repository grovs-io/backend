module Segments
  class DeviceCondition
    FIELDS = %w[platform os os_version app_version device_model language country].freeze
    PROFILE_FIELDS = %w[platform country].freeze
    OPS = %w[is is_not contains].freeze
    MODES = %w[current used].freeze
    CURRENT_DAYS = Integer(ENV.fetch("SEGMENT_DEVICE_CURRENT_DAYS", 30))

    def self.build(raw, path:, errors:, cutoff_date:)
      before = errors.size
      field = raw["field"].to_s
      op = raw["op"].to_s
      mode = raw.fetch("mode", "current").to_s
      errors << { path: "#{path}.field", message: "field must be one of #{FIELDS.join(', ')}" } unless FIELDS.include?(field)
      errors << { path: "#{path}.op", message: "op must be one of #{OPS.join(', ')}" } unless OPS.include?(op)
      errors << { path: "#{path}.mode", message: "mode must be current or used" } unless MODES.include?(mode)
      values = Quoting.clean_values(raw["value"], path: "#{path}.value", errors: errors)
      window = nil
      if mode == "used"
        window = Window.normalize(raw["window"], cap_days: EventCondition::LOOKBACK_DAYS, cutoff_date: cutoff_date,
                                                  path: "#{path}.window", errors: errors)
      end
      return nil if errors.size > before

      new("field" => field, "op" => op, "value" => values, "mode" => mode, "window" => window)
    end

    def self.column(field)
      field == "platform" ? ClickhouseReadService.normalized_platform_sql : field
    end

    # platform/country come from user_profiles; the other fields exist only on events.
    def self.shared_current_rows_sql(env, pairs)
      b = Window.bounds({ "last_days" => CURRENT_DAYS }, cutoff_date: env.cutoff_date, now: env.now)
      profile, events = pairs.partition { |cond, _| PROFILE_FIELDS.include?(cond.to_h["field"]) }
      parts = []
      parts << current_rows_from("user_profiles", "last_seen", profile, env, b) if profile.any?
      parts << current_rows_from("events", "created_at", events, env, b) if events.any?
      parts.join(" UNION ALL ")
    end

    def self.current_rows_from(table, ts_column, pairs, env, bounds)
      kvs = pairs.map { |cond, idx| "(toUInt8(#{idx}), toString(argMax(#{column(cond.to_h['field'])}, #{ts_column})))" }
      "SELECT visitor_id, kv.1 AS ci, toUInt64(toUnixTimestamp64Milli(ts)) AS n, kv.2 AS s FROM (" \
        "SELECT visitor_id, max(#{ts_column}) AS ts, [#{kvs.join(', ')}] AS kvs FROM #{table} " \
        "WHERE project_id = #{Integer(env.project_id)} AND visitor_id != 0 AND #{Window.sql(ts_column, bounds)} " \
        "GROUP BY visitor_id) ARRAY JOIN kvs AS kv"
    end

    # Reserved ci=0 row for the platform breakdown; candidates_sql bounds the whole-project scan.
    def self.platform_tag_rows_sql(env, candidates_sql)
      b = Window.bounds({ "last_days" => CURRENT_DAYS }, cutoff_date: env.cutoff_date, now: env.now)
      "SELECT visitor_id, toUInt8(0) AS ci, toUInt64(1) AS n, plat AS s FROM (" \
        "SELECT visitor_id, argMax(#{column('platform')}, last_seen) AS plat FROM user_profiles " \
        "WHERE project_id = #{Integer(env.project_id)} AND visitor_id != 0 AND #{Window.sql('last_seen', b)} " \
        "AND visitor_id IN (SELECT visitor_id FROM (#{candidates_sql})) " \
        "GROUP BY visitor_id)"
    end

    def initialize(attrs) = @attrs = attrs

    def to_h = { "type" => "device" }.merge(@attrs).compact
    # A current is_not needs a known current value, so it is positive, not the complement of is.
    def negative? = @attrs["op"] == "is_not" && !current?
    def current? = @attrs["mode"] == "current"
    def window = current? ? { "last_days" => CURRENT_DAYS } : @attrs["window"]

    def rows_sql(env, idx)
      return nil if current?

      b = Window.bounds(window, cutoff_date: env.cutoff_date, now: env.now)
      "SELECT visitor_id, toUInt8(#{idx}) AS ci, toUInt64(1) AS n, '' AS s FROM events " \
        "WHERE project_id = #{Integer(env.project_id)} AND visitor_id != 0 AND #{Window.sql('created_at', b)} " \
        "AND #{Grovs::Events::NOT_A_SERVER_EVENT_SQL} " \
        "AND #{Quoting.string_clause(self.class.column(@attrs['field']), positive_op, @attrs['value'])} GROUP BY visitor_id"
    end

    def predicate(idx)
      return "countIf(r.ci = #{idx}) > 0" unless current?

      latest = "argMaxIf(r.s, r.n, r.ci = #{idx})"
      sql = "countIf(r.ci = #{idx}) > 0 AND " + Quoting.string_clause(latest, positive_op, @attrs["value"])
      # Unknown is stored as '', which NOT IN would count as a match.
      @attrs["op"] == "is_not" ? "#{sql} AND #{latest} != ''" : sql
    end

    private

    def positive_op = negative? ? "is" : @attrs["op"]
  end
end
