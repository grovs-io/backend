# frozen_string_literal: true

module Analytics
  # Dimensions from events, identity from the published snapshot; sync identities first.
  module UserProfileBackfillService
    module_function

    # Memory + parallelism guards so a high-cardinality tenant can't OOM the server.
    MAX_MEMORY_BYTES =
      Integer(ENV.fetch('CLICKHOUSE_BACKFILL_MAX_MEMORY_BYTES', 4_000_000_000))
    MAX_BYTES_BEFORE_EXTERNAL_GROUP_BY =
      Integer(ENV.fetch('CLICKHOUSE_BACKFILL_MAX_BYTES_BEFORE_EXTERNAL_GROUP_BY', 2_000_000_000))
    MAX_THREADS =
      Integer(ENV.fetch('CLICKHOUSE_BACKFILL_MAX_THREADS', 4))
    # Big tenants aggregate for minutes — past the ~120s HTTP read timeout; raise both it
    # and ClickHouse's max_execution_time.
    REQUEST_TIMEOUT_SECONDS =
      Integer(ENV.fetch('CLICKHOUSE_BACKFILL_REQUEST_TIMEOUT_SECONDS', 3600))

    # Additive backfill; the INSERT is the whole operation (no read-back count — a
    # post-insert query could time out and mask a committed insert as a failure).
    # shards > 1 splits into N passes by `visitor_id % N` so a giant tenant whose
    # single-pass GROUP BY exceeds server memory still fits (each pass re-scans events).
    # shards: :auto sizes N per project from its visitor count so every project fits.
    MissingIdentitiesError = Class.new(StandardError)

    def backfill_project(project_id, shards: :auto)
      pid = Integer(project_id)
      require_published_identities!(pid)
      horizon = Time.current.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')

      Clickhouse.with_request_timeout(REQUEST_TIMEOUT_SECONDS) do
        n = shards == :auto ? auto_shards(pid) : Integer(shards)
        raise ArgumentError, 'shards must be >= 1' if n < 1

        n.times do |i|
          shard_clause = n > 1 ? "AND visitor_id % #{n} = #{i}" : ''
          Clickhouse.with { |conn| conn.execute(backfill_sql(pid, horizon, shard_clause)) }
        end
      end
      nil
    end

    # Additive write: without identities it burns in blanks no later run can repair.
    def require_published_identities!(pid)
      return if ENV['ALLOW_MISSING_VISITOR_IDENTITIES'] == '1'
      return if ClickhouseReadService.published_identity_generation?(pid)

      raise MissingIdentitiesError,
            "project #{pid} has no published visitor identities — run " \
            'rake clickhouse:sync_visitor_identities first (or set ALLOW_MISSING_VISITOR_IDENTITIES=1 ' \
            'to accept permanently blank identities)'
    end

    # Shards needed to keep each pass's visitor count under the per-shard target, so a
    # giant tenant fits under server memory without hand-tuning. uniq (approximate HLL)
    # keeps the sizing scan cheap on memory; rounding up adds margin.
    def auto_shards(project_id)
      target = Integer(ENV.fetch('CLICKHOUSE_BACKFILL_VISITORS_PER_SHARD', 1_000_000))
      count = Clickhouse.with do |conn|
        conn.select_value("SELECT uniq(visitor_id) FROM events WHERE project_id = #{Integer(project_id)} AND visitor_id != 0")
      end.to_i
      [(count.to_f / target).ceil, 1].max
    end

    def backfill_sql(pid, horizon, shard_clause)
      <<~SQL
        INSERT INTO user_profiles
          (project_id, visitor_id, first_seen, last_seen, platform, country, sdk_identifier, uuid, inviter_id)
        SELECT
          agg.project_id,
          agg.visitor_id,
          agg.first_seen,
          agg.last_seen,
          agg.platform,
          agg.country,
          if(vi.synced = 1, vi.sdk_identifier, agg.sdk_identifier) AS sdk_identifier,
          vi.uuid,
          agg.inviter_id
        FROM (
          SELECT
            project_id,
            visitor_id,
            min(created_at) AS first_seen,
            max(created_at) AS last_seen,
            argMax(if(platform IN ('android', 'ios'), platform, 'web'), (created_at, event_id)) AS platform,
            argMax(country, (created_at, event_id)) AS country,
            argMax(sdk_identifier, (created_at, event_id)) AS sdk_identifier,
            argMax(inviter_id, (created_at, event_id)) AS inviter_id
          FROM events
          WHERE project_id = #{pid}
            AND visitor_id != 0
            AND created_at <= toDateTime64('#{horizon}', 3, 'UTC')
            #{shard_clause}
            AND visitor_id NOT IN (SELECT visitor_id FROM user_profiles WHERE project_id = #{pid})
          GROUP BY project_id, visitor_id
        ) agg
        LEFT JOIN (
          SELECT visitor_id, sdk_identifier, uuid, 1 AS synced
          FROM visitor_identities
          WHERE project_id = #{pid}
            AND visitor_id != #{VisitorIdentitySyncService::GENERATION_MARKER_VISITOR_ID}
            AND synced_at = #{VisitorIdentitySyncService.published_generation_sql(pid)}
            #{shard_clause}
        ) vi USING (visitor_id)
        SETTINGS max_memory_usage = #{MAX_MEMORY_BYTES},
                 max_bytes_before_external_group_by = #{MAX_BYTES_BEFORE_EXTERNAL_GROUP_BY},
                 max_threads = #{MAX_THREADS},
                 max_execution_time = #{REQUEST_TIMEOUT_SECONDS}
      SQL
    end

    def project_ids_with_events
      rows = Clickhouse.with do |conn|
        conn.select_all('SELECT DISTINCT project_id FROM events ORDER BY project_id')
      end
      rows.map { |r| r['project_id'].to_i }
    end
  end
end
