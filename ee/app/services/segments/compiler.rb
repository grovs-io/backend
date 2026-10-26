module Segments
  class Compiler
    Env = Struct.new(:project_id, :cutoff_date, :now, :segment_id, :list_generation)
    # CH keeps the inner clause on a duplicate key here, so Runner must not override this setting.
    JOIN_SETTINGS = "SETTINGS join_use_nulls = 0".freeze

    def initialize(definition, project_id:, cutoff_date:, now: Time.now.utc, segment_id: nil, list_generation: nil)
      unless definition.valid?
        raise InvalidDefinition, definition.errors.first(5).map { |e| "#{e[:path]}: #{e[:message]}" }.join(", ")
      end

      @definition = definition
      @env = Env.new(Integer(project_id), cutoff_date, now, segment_id, list_generation)
      @indexed = definition.conditions.each_with_index.map { |cond, i| [cond, i + 1] }
    end

    def incomplete?
      @indexed.any? { |cond, _| stale?(cond) }
    end

    def members_sql
      guard_window!

      <<~SQL.squish
        WITH #{PersonMap.cte(@env.project_id)}
        SELECT pk, members FROM (
          SELECT #{pk_sql} AS pk,
                 groupUniqArray((if(v.raw_id = 0, r.visitor_id, v.raw_id), if(v.raw_id = 0, r.visitor_id, v.eff_id))) AS members,
                 (#{predicate}) AS ok
          #{from_join_sql}
          GROUP BY pk
        ) WHERE ok
        #{JOIN_SETTINGS}
      SQL
    end

    def estimate_sql
      guard_window!

      <<~SQL.squish
        WITH #{PersonMap.cte(@env.project_id)}
        SELECT count() AS persons, sum(dev) AS devices FROM (
          SELECT #{pk_sql} AS pk, uniqExact(if(v.raw_id = 0, r.visitor_id, v.eff_id)) AS dev, (#{predicate}) AS ok
          #{from_join_sql}
          GROUP BY pk
        ) WHERE ok
        #{JOIN_SETTINGS}
      SQL
    end

    def insert_members_sql(result_id)
      raise ArgumentError, "bad result id" unless result_id.to_s.match?(/\A\h{32}\z/)

      # Paging needs an (eff, eff) row per effective visitor; a mid-merge chain may lack one.
      "INSERT INTO segment_results (project_id, result_id, visitor_id, eff_visitor_id, person_key) " \
        "SELECT #{@env.project_id}, '#{result_id}', m.1, m.2, pk FROM (#{members_sql}) " \
        "ARRAY JOIN arrayDistinct(arrayConcat(members, arrayMap(t -> (t.2, t.2), members))) AS m"
    end

    # ci=0 is reserved; only the survivor's platform counts, as delivery uses it.
    def estimate_with_platforms_sql
      guard_window!
      effid_sql = "if(v.raw_id = 0, r.visitor_id, v.eff_id)"
      tag = DeviceCondition.platform_tag_rows_sql(@env, row_sources.join(" UNION ALL "))
      survivor = "r.ci = 0 AND (v.raw_id = 0 OR v.raw_id = v.eff_id)"

      <<~SQL.squish
        WITH #{PersonMap.cte(@env.project_id)}
        SELECT count() AS persons, sum(dev) AS devices, sum(ios_dev) AS ios_devices, sum(android_dev) AS android_devices FROM (
          SELECT #{pk_sql} AS pk, uniqExact(#{effid_sql}) AS dev,
                 uniqCombinedIf(#{effid_sql}, #{survivor} AND r.s = 'ios') AS ios_dev,
                 uniqCombinedIf(#{effid_sql}, #{survivor} AND r.s = 'android') AS android_dev,
                 (#{predicate}) AS ok
          #{from_join_sql([tag])}
          GROUP BY pk
        ) WHERE ok
        #{JOIN_SETTINGS}
      SQL
    end

    private

    def guard_window!
      raise WindowExpired, "a negative condition's window is older than retention" if @indexed.any? { |c, _| c.negative? && stale?(c) }
    end

    def pk_sql
      "if(v.person_key = '', concat('v:', toString(r.visitor_id)), v.person_key)"
    end

    def from_join_sql(extra_sources = [])
      "FROM (#{(row_sources + extra_sources).join(' UNION ALL ')}) AS r FULL OUTER JOIN vmap AS v ON v.raw_id = r.visitor_id"
    end

    def stale?(cond)
      cond.window.present? && Window.bounds(cond.window, cutoff_date: @env.cutoff_date, now: @env.now).incomplete
    end

    def row_sources
      current = @indexed.select { |cond, _| cond.respond_to?(:current?) && cond.current? }
      sources = @indexed.filter_map { |cond, idx| cond.rows_sql(@env, idx) }
      sources << DeviceCondition.shared_current_rows_sql(@env, current) if current.any?
      sources
    end

    def predicate
      index_of = {}.compare_by_identity
      @indexed.each { |cond, idx| index_of[cond] = idx }
      groups = @definition.groups.map do |group|
        parts = group.conditions.map do |cond|
          sql = cond.predicate(index_of.fetch(cond))
          cond.negative? ? "NOT (#{sql})" : "(#{sql})"
        end
        "(#{parts.join(group.operator == 'and' ? ' AND ' : ' OR ')})"
      end
      groups.join(@definition.operator == "and" ? " AND " : " OR ")
    end
  end
end
