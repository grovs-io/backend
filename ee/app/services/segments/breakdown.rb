module Segments
  module Breakdown
    DIMENSIONS = %w[platform country app_version source campaign first_seen_week].freeze
    TOP = 50
    TIMEOUT = 40
    INSTALL_DAYS = 365
    EVENT_COLUMNS = { "platform" => "platform", "country" => "country", "app_version" => "app_version",
                      "source" => "tracking_source", "campaign" => "campaign_id" }.freeze

    def self.call(project:, manifest:, by:, lane: :dashboard)
      by = by.to_s
      raise ArgumentError, "unknown dimension" unless DIMENSIONS.include?(by) || property_key(by)

      rows = Runner.run(project.id, sql(project, manifest, by), timeout: TIMEOUT, lane: lane)
      { by: by, total_persons: manifest.persons, buckets: fold(rows, manifest.persons, by, project) }
    end

    def self.property_key(by)
      key = by.delete_prefix("properties.")
      key if by.start_with?("properties.") && Analytics::EventsQueryService.valid_property_key?(key)
    end

    def self.sql(project, manifest, by)
      source, pick = source_for(project, manifest, by)
      per_person = "SELECT sr.person_key AS pk, #{pick} AS bucket FROM (#{source}) AS x " \
        "INNER JOIN (SELECT visitor_id, person_key FROM segment_results WHERE #{Results.scope_sql(manifest)}) AS sr " \
        "ON sr.visitor_id = x.visitor_id GROUP BY pk"
      # valued is a window total taken before LIMIT, so the top-50 cut never counts as "unknown".
      "SELECT bucket, persons, sum(persons) OVER () AS valued FROM (" \
        "SELECT bucket, count() AS persons FROM (#{per_person}) WHERE bucket != '' GROUP BY bucket" \
        ") ORDER BY persons DESC, bucket ASC LIMIT #{TOP}"
    end

    def self.source_for(project, manifest, by)
      pid = Integer(project.id)
      member = "visitor_id IN (SELECT visitor_id FROM segment_results WHERE #{Results.scope_sql(manifest)})"
      if (key = property_key(by))
        ["SELECT visitor_id, argMax(ifNull(CAST(properties.`#{key}` AS Nullable(String)), ''), last_seen) AS val, " \
         "max(last_seen) AS ts FROM user_profiles WHERE project_id = #{pid} AND visitor_id != 0 AND #{member} " \
         "GROUP BY visitor_id HAVING val != ''",
         "argMax(x.val, x.ts)"]
      elsif by == "first_seen_week"
        ["SELECT visitor_id, '' AS val, minMerge(first_seen_state) AS ts FROM visitor_first_seen_daily " \
         "WHERE project_id = #{pid} AND #{member} GROUP BY visitor_id", "toString(toMonday(min(x.ts)))"]
      else
        events_source(project, pid, member, by)
      end
    end

    def self.events_source(project, pid, member, by)
      cutoff = Analytics::RetentionPolicy.for(project.instance).queryable_cutoff_date
      install = %w[source campaign].include?(by)
      days = install ? INSTALL_DAYS : DeviceCondition::CURRENT_DAYS
      bounds = Window.bounds({ "last_days" => days }, cutoff_date: cutoff, now: Time.now.utc)
      column = by == "platform" ? ClickhouseReadService.normalized_platform_sql : EVENT_COLUMNS.fetch(by)
      types = install ? " AND event_type IN (#{AcquisitionCondition::INSTALL_TYPES.map { |t| Quoting.literal(t) }.join(', ')})" : ""
      agg = install ? "argMin" : "argMax"
      # A person with several visitors must never be tied to a valueless device (see HAVING below).
      having = by == "campaign" ? "val NOT IN ('', '0')" : "val != ''"
      ["SELECT visitor_id, #{agg}(toString(#{column}), created_at) AS val, #{install ? 'min' : 'max'}(created_at) AS ts FROM events " \
       "WHERE project_id = #{pid} AND visitor_id != 0 AND #{Window.sql('created_at', bounds)}#{types} AND #{member} " \
       "AND #{Grovs::Events::NOT_A_SERVER_EVENT_SQL} " \
       "GROUP BY visitor_id HAVING #{having}",
       "#{agg}(x.val, x.ts)"]
    end

    def self.fold(rows, total, by, project)
      top = rows.map { |r| { value: r["bucket"].to_s, persons: r["persons"].to_i } }
      valued = rows.first ? rows.first["valued"].to_i : 0
      other = valued - top.sum { |b| b[:persons] }
      top << { value: "other", persons: other } if other.positive?
      unknown = total - valued
      top << { value: "unknown", persons: unknown } if unknown.positive?
      label(top, by, project)
    end

    def self.label(buckets, by, project)
      names = by == "campaign" ? Campaign.where(project_id: project.id, id: buckets.map { |b| b[:value].to_i }).pluck(:id, :name).to_h : {}
      buckets.map { |b| b.merge(label: names[b[:value].to_i] || b[:value]) }
    end
  end
end
