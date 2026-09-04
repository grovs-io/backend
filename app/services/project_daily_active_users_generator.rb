# app/services/project_daily_active_users_generator.rb
class ProjectDailyActiveUsersGenerator
  # Fallback shards, used ONLY when the single-pass query times out: a slow/huge project
  # otherwise fails the whole-day query and wipes DAU for every project that run. Sharded
  # retry lets the healthy shards still land (each shard scans the day, so it's 16x the
  # work — acceptable only on the degraded path, never the happy path).
  SHARD_COUNT = 16

  class << self
    # COUNT(*) equals COUNT(DISTINCT visitor_id) here — the unique index gives one row per visitor/day.
    def call(date)
      # Gated here, not in the two callers — the admin flush endpoint calls this directly.
      return unless Grovs.pg_shadow_writes?

      date = date.to_date
      run_upsert(date)
    rescue ActiveRecord::QueryCanceled => e
      Rails.logger.warn(
        "ProjectDailyActiveUsersGenerator: single-pass timed out (#{e.message}), retrying in #{SHARD_COUNT} shards"
      )
      run_sharded(date)
    end

    private

    def run_sharded(date)
      SHARD_COUNT.times do |shard|
        run_upsert(date, shard: shard, statement_timeout: "2min")
      rescue ActiveRecord::QueryCanceled => e
        # Isolated: one slow shard must not drop the rest of the day's DAU.
        Rails.logger.error("ProjectDailyActiveUsersGenerator: shard #{shard} timed out (#{e.message}), skipping")
      end
    end

    def run_upsert(date, shard: nil, statement_timeout: "8min")
      # shard is a 0..SHARD_COUNT-1 integer from the loop; Integer() guards the interpolation.
      shard_filter = shard.nil? ? "" : "AND (vds.project_id % #{SHARD_COUNT}) = #{Integer(shard)}"

      sql = ActiveRecord::Base.send(
        :sanitize_sql_array,
        [<<~SQL, date, date]
          INSERT INTO project_daily_active_users
            (project_id, event_date, platform, active_users, created_at, updated_at)
          SELECT
            vds.project_id,
            ?::date AS event_date,
            vds.platform,
            COUNT(*) AS active_users,
            NOW(), NOW()
          FROM visitor_daily_statistics vds
          WHERE vds.event_date = ?::date #{shard_filter}
          GROUP BY vds.project_id, vds.platform
          ORDER BY vds.project_id, vds.platform
          ON CONFLICT (project_id, event_date, platform)
          DO UPDATE SET active_users = EXCLUDED.active_users,
                        updated_at   = NOW();
        SQL
      )

      ActiveRecord::Base.with_connection do |conn|
        conn.transaction do
          # 5s lock_timeout: if a row is locked, fail fast and let the next 10-min run pick
          # it up rather than blocking. statement_timeout caps the scan per (shard) query.
          conn.execute("SET LOCAL lock_timeout = '5s'")
          conn.execute("SET LOCAL statement_timeout = '#{statement_timeout}'")
          conn.execute(sql)
        end
      end
    end
  end
end
