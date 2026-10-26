module Segments
  class EventCondition
    LOOKBACK_DAYS = Integer(ENV.fetch("SEGMENT_EVENT_LOOKBACK_DAYS", 90))
    MAX_FILTERS = Analytics::QueryHelpers::MAX_FILTERS
    FILTER_COLUMNS = %w[screen_name platform app_version country city device_model os os_version language
                        tracking_source tracking_medium tracking_campaign ads_platform].freeze
    PROPERTY_PREFIX = "properties.".freeze

    def self.build(raw, path:, errors:, cutoff_date:)
      before = errors.size
      match = build_match(raw, path, errors)
      count = raw.key?("count") ? Quoting.strict_int(raw["count"]) : 1
      errors << { path: "#{path}.count", message: "count must be an integer >= 1" } unless count&.positive?
      window = Window.normalize(raw["window"], cap_days: LOOKBACK_DAYS, cutoff_date: cutoff_date,
                                                path: "#{path}.window", errors: errors)
      filters = build_filters(raw["filters"], path, errors)
      negate = Quoting.strict_flag(raw, "negate", path, errors)
      return nil if errors.size > before

      new("match" => match, "filters" => filters, "count" => count, "window" => window, "negate" => negate)
    end

    def self.build_match(raw, path, errors)
      given = %w[event_type event_name].select { |k| raw[k].present? }
      given << "any" if Quoting.strict_flag(raw, "any", path, errors)
      unless given.size == 1
        errors << { path: path, message: "give exactly one of event_type, event_name, any" }
        return nil
      end
      case given.first
      when "any" then { "kind" => "any", "value" => "" }
      when "event_name" then build_event_name(raw["event_name"], path, errors)
      else
        type = raw["event_type"].to_s
        errors << { path: "#{path}.event_type", message: "event_type is not a known built-in event" } unless Grovs::Events::ALL.include?(type)
        { "kind" => "type", "value" => type }
      end
    end

    def self.build_event_name(name, path, errors)
      unless name.is_a?(String) && name.bytesize.between?(1, Quoting::MAX_BYTES)
        errors << { path: "#{path}.event_name", message: "event_name must be a string of at most #{Quoting::MAX_BYTES} bytes" }
        return nil
      end
      { "kind" => "name", "value" => name }
    end

    def self.build_filters(raw, path, errors)
      unless raw.nil? || raw.is_a?(Array)
        errors << { path: "#{path}.filters", message: "filters must be an array" }
        return []
      end
      list = Array(raw)
      errors << { path: "#{path}.filters", message: "at most #{MAX_FILTERS} filters" } if list.size > MAX_FILTERS
      list.first(MAX_FILTERS).each_with_index.filter_map do |f, i|
        fpath = "#{path}.filters[#{i}]"
        unless f.is_a?(Hash)
          errors << { path: fpath, message: "filter must be an object" }
          next nil
        end
        field = f["field"].to_s
        op = f["op"].to_s
        errors << { path: fpath, message: "field is not filterable" } unless filterable?(field)
        errors << { path: fpath, message: "op must be one of #{Quoting::STRING_OPS.join(', ')}" } unless Quoting::STRING_OPS.include?(op)
        values = Quoting.clean_values(f["value"], path: fpath, errors: errors)
        { "field" => field, "op" => op, "value" => values } if values
      end
    end

    def self.filterable?(field)
      return true if FILTER_COLUMNS.include?(field)

      field.start_with?(PROPERTY_PREFIX) &&
        Analytics::EventsQueryService.valid_property_key?(field.delete_prefix(PROPERTY_PREFIX))
    end

    def initialize(attrs) = @attrs = attrs

    # Emits the same keys .build reads, so a stored canonical definition re-parses unchanged.
    def to_h
      m = @attrs["match"]
      key = { "type" => "event_type", "name" => "event_name" }[m["kind"]]
      head = key ? { key => m["value"] } : { "any" => true }
      { "type" => "event" }.merge(head).merge(@attrs.except("match"))
    end
    def negative? = @attrs["negate"]
    def window = @attrs["window"]

    def rows_sql(env, idx)
      b = Window.bounds(window, cutoff_date: env.cutoff_date, now: env.now)
      return daily_rows_sql(env, idx, b) if daily_eligible?

      where = ["project_id = #{Integer(env.project_id)}", "visitor_id != 0", Window.sql("created_at", b)]
      where << match_sql if match_sql
      # As the rollup does: a message shown to a person is not something the person did.
      where << Grovs::Events::NOT_A_MESSAGE_SQL if counts_custom?
      where.concat(@attrs["filters"].map { |f| Quoting.string_clause(column_for(f["field"]), f["op"], f["value"]) })
      "SELECT visitor_id, toUInt8(#{idx}) AS ci, uniqExact(sipHash64(event_id)) AS n, '' AS s FROM events " \
        "WHERE #{where.join(' AND ')} GROUP BY visitor_id"
    end

    def predicate(idx) = "sumIf(r.n, r.ci = #{idx}) >= #{Integer(@attrs['count'])}"

    private

    # The rollup has no event_name or filter columns, so named or filtered conditions scan events.
    def daily_eligible?
      %w[type any].include?(@attrs["match"]["kind"]) && @attrs["filters"].empty?
    end

    def daily_rows_sql(env, idx, bounds)
      where = ["project_id = #{Integer(env.project_id)}", "visitor_id != 0",
                "event_date >= '#{bounds.from.utc.to_date}'", "event_date <= '#{bounds.to.utc.to_date}'"]
      where << "event_type = #{Quoting.literal(@attrs['match']['value'])}" if @attrs["match"]["kind"] == "type"
      "SELECT visitor_id, toUInt8(#{idx}) AS ci, toUInt64(sum(cnt)) AS n, '' AS s FROM visitor_daily " \
        "WHERE #{where.join(' AND ')} GROUP BY visitor_id"
    end

    def counts_custom?
      m = @attrs["match"]
      m["kind"] == "any" || (m["kind"] == "type" && m["value"] == Grovs::Events::CUSTOM)
    end

    def match_sql
      m = @attrs["match"]
      case m["kind"]
      when "type" then "event_type = #{Quoting.literal(m['value'])}"
      # SDK ingestion stores every named event as custom/screen_view, so the type prunes the scan.
      when "name" then "event_type = #{Quoting.literal(name_event_type(m['value']))} AND event_name = #{Quoting.literal(m['value'])}"
      end
    end

    def name_event_type(name)
      name == Grovs::Events::SCREEN_VIEW ? Grovs::Events::SCREEN_VIEW : Grovs::Events::CUSTOM
    end

    def column_for(field)
      return ClickhouseReadService.normalized_platform_sql if field == "platform"
      return field if FILTER_COLUMNS.include?(field)

      "CAST(properties.`#{field.delete_prefix(PROPERTY_PREFIX)}` AS String)"
    end
  end
end
