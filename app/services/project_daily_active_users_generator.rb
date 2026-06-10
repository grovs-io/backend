# app/services/project_daily_active_users_generator.rb
class ProjectDailyActiveUsersGenerator
  class << self
    # DAU (distinct visitors) per project+platform for a date, in one GROUP BY pass
    # (was 16 sharded queries each scanning the whole day). COUNT(*) is safe because
    # the unique (project_id, visitor_id, event_date, platform) index gives one row
    # per visitor/day, so it equals COUNT(DISTINCT visitor_id) without the dedup sort.
    def call(date)
      date = date.to_date

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
          WHERE vds.event_date = ?::date
          GROUP BY vds.project_id, vds.platform
          ON CONFLICT (project_id, event_date, platform)
          DO UPDATE SET active_users = EXCLUDED.active_users,
                        updated_at   = NOW();
        SQL
      )

      ActiveRecord::Base.with_connection do |conn|
        conn.transaction do
          # 5s lock_timeout: single upsert now (was 1s per-shard). The upsert touches
          # the small project_daily_active_users aggregate table; if a row is locked,
          # fail fast and let the next 10-min run pick it up rather than blocking.
          conn.execute("SET LOCAL lock_timeout = '5s'")
          # 8min statement_timeout: the single-pass COUNT(DISTINCT) GROUP BY over a
          # day of visitor_daily_statistics must finish within one Sidekiq job cycle.
          conn.execute("SET LOCAL statement_timeout = '8min'")
          conn.execute(sql)
        end
      end
    end
  end
end
