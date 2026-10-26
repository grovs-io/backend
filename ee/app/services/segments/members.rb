module Segments
  module Members
    MAX_LIMIT = 200

    # A page may hold fewer than limit users with next_after set: PG-missing rows drop after paging.
    def self.page(manifest:, after: 0, limit: 50, max: MAX_LIMIT, q: nil)
      limit = Integer(limit).clamp(1, max)
      rows = Runner.read(
        "SELECT visitor_id, person_key FROM segment_results WHERE #{effective_after_sql(manifest, after)}" \
        "#{search_sql(manifest.project_id, q)} ORDER BY visitor_id LIMIT #{limit + 1}"
      )
      more = rows.size > limit
      rows = rows.first(limit)
      { users: hydrate(manifest.project_id, rows), next_after: more ? rows.last["visitor_id"].to_i : nil }
    end

    # One (eff, eff) row per effective visitor, so pages follow the sort key with no GROUP BY.
    def self.effective_after_sql(manifest, after)
      "#{Results.scope_sql(manifest)} AND visitor_id > #{Integer(after)} AND visitor_id = eff_visitor_id"
    end

    # Identifier substring or uuid prefix; live user_profiles cover people the last identity sync missed.
    def self.search_sql(project_id, q)
      term = q.to_s.strip.first(100)
      return "" if term.empty?

      pid = Integer(project_id)
      lit = Quoting.literal(term)
      match = ->(ident, uuid) { "(positionCaseInsensitive(#{ident}, #{lit}) > 0 OR startsWith(lower(#{uuid}), lower(#{lit})))" }
      synced = "project_id = #{pid} AND synced_at = #{Analytics::VisitorIdentitySyncService.published_generation_sql(pid)} " \
               "AND visitor_id != #{Analytics::VisitorIdentitySyncService::GENERATION_MARKER_VISITOR_ID}"
      # Matching rows narrow the candidates; only each candidate's newest identity decides.
      cand = "SELECT visitor_id FROM user_profiles WHERE project_id = #{pid} AND #{match.call('sdk_identifier', 'uuid')} " \
             "UNION ALL SELECT visitor_id FROM visitor_identities WHERE #{synced} AND #{match.call('sdk_identifier', 'uuid')}"
      " AND eff_visitor_id IN (SELECT visitor_id FROM (" \
        "SELECT visitor_id, argMax(sdk_identifier, (observed_at, live)) AS ident, argMax(uuid, (observed_at, live)) AS id_uuid FROM (" \
        "SELECT visitor_id, sdk_identifier, uuid, toDateTime64(synced_at, 3) AS observed_at, 0 AS live FROM visitor_identities " \
        "WHERE #{synced} AND visitor_id IN (#{cand}) " \
        "UNION ALL SELECT visitor_id, sdk_identifier, uuid, last_seen AS observed_at, 1 AS live FROM user_profiles " \
        "WHERE project_id = #{pid} AND visitor_id IN (#{cand})) GROUP BY visitor_id) WHERE #{match.call('ident', 'id_uuid')})"
    end

    def self.hydrate(project_id, rows)
      ids = rows.map { |r| r["visitor_id"].to_i }
      by_id = Visitor.where(project_id: project_id, id: ids).index_by(&:id)
      rows.filter_map do |row|
        visitor = by_id[row["visitor_id"].to_i]
        next unless visitor

        VisitorSerializer.serialize(visitor, slim: true).merge("person_key" => row["person_key"])
      end
    end

    # The cursor carries the search term too, so page 2 can never silently widen to the whole segment.
    def self.encode_cursor(result_id, after, q = nil)
      Base64.urlsafe_encode64({ "r" => result_id, "a" => Integer(after), "q" => q.to_s }.to_json, padding: false)
    end

    def self.decode_cursor(token)
      data = JSON.parse(Base64.urlsafe_decode64(token.to_s))
      [data.fetch("r").to_s, Integer(data.fetch("a")), data["q"].to_s]
    rescue ArgumentError, JSON::ParserError, KeyError, TypeError
      raise ResultExpired, "bad cursor"
    end
  end
end
