module Segments
  module PersonMap
    MAX_VISITORS = Integer(ENV.fetch("SEGMENT_IDENTIFIER_MAX_VISITORS", 50))

    # A String state per visitor cost ~9s at 8M visitors; FINAL over user_profiles risks OOM.
    def self.cte(project_id)
      pid = Integer(project_id)
      generation = Analytics::VisitorIdentitySyncService.published_generation_sql(pid)
      marker = Analytics::VisitorIdentitySyncService::GENERATION_MARKER_VISITOR_ID
      cand = candidates_sql(pid, generation, marker)
      <<~SQL.squish
        vmap AS (
          SELECT raw_id, eff_id,
                 if(ident != '' AND uniqExact(eff_id) OVER (PARTITION BY ident) <= #{MAX_VISITORS},
                    concat('i:', ident), concat('v:', toString(eff_id))) AS person_key
          FROM (
            SELECT raw_id, eff_id,
                   anyIf(raw_ident, raw_id = eff_id) OVER w AS ident
            FROM (
              SELECT ids.raw_id AS raw_id, ids.raw_ident AS raw_ident,
                     if(m.to_visitor_id > 0, m.to_visitor_id, ids.raw_id) AS eff_id
              FROM (
                SELECT visitor_id AS raw_id, argMax(sdk_identifier, (observed_at, live)) AS raw_ident
                FROM (
                  SELECT visitor_id, sdk_identifier, toDateTime64(synced_at, 3) AS observed_at, 0 AS live
                  FROM visitor_identities
                  WHERE project_id = #{pid} AND visitor_id != #{marker} AND synced_at = #{generation}
                    AND visitor_id IN (#{cand})
                  UNION ALL
                  SELECT visitor_id, sdk_identifier, last_seen AS observed_at, 1 AS live
                  FROM user_profiles WHERE project_id = #{pid} AND visitor_id IN (#{cand})
                  UNION ALL
                  SELECT from_visitor_id AS visitor_id, '' AS sdk_identifier, toDateTime64(0, 3) AS observed_at, 0 AS live
                  FROM visitor_identity_map WHERE project_id = #{pid}
                  UNION ALL
                  SELECT to_visitor_id AS visitor_id, '' AS sdk_identifier, toDateTime64(0, 3) AS observed_at, 0 AS live
                  FROM visitor_identity_map WHERE project_id = #{pid}
                )
                GROUP BY visitor_id
              ) AS ids
              LEFT JOIN (
                SELECT from_visitor_id, argMax(to_visitor_id, updated_at) AS to_visitor_id
                FROM visitor_identity_map WHERE project_id = #{pid} GROUP BY from_visitor_id
              ) AS m ON m.from_visitor_id = ids.raw_id
            )
            WINDOW w AS (PARTITION BY eff_id)
          )
        )
      SQL
    end

    def self.candidates_sql(pid, generation, marker)
      <<~SQL.squish
        SELECT visitor_id FROM visitor_identities
        WHERE project_id = #{pid} AND synced_at = #{generation} AND visitor_id != #{marker} AND sdk_identifier != ''
        UNION ALL
        SELECT visitor_id FROM user_profiles WHERE project_id = #{pid} AND sdk_identifier != ''
        UNION ALL
        SELECT from_visitor_id FROM visitor_identity_map WHERE project_id = #{pid}
        UNION ALL
        SELECT to_visitor_id FROM visitor_identity_map WHERE project_id = #{pid}
      SQL
    end
  end
end
