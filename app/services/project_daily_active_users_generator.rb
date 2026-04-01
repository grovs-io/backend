# app/services/project_daily_active_users_generator.rb
class ProjectDailyActiveUsersGenerator
  SHARDS = 16 # tune: 8-64

  class << self
    def call(date)
      date = date.to_date
      SHARDS.times { |shard| upsert_shard(date, shard) }
    end

    private

    def upsert_shard(date, shard)
      sql = ActiveRecord::Base.send(
        :sanitize_sql_array,
        [<<~SQL, date, date, SHARDS, shard]
          /* project_dau shard #{shard} (mod by project_id) */
          INSERT INTO project_daily_active_users
            (project_id, event_date, platform, active_users, created_at, updated_at)
          SELECT
            vds.project_id,
            ?::date AS event_date,
            vds.platform,
            COUNT(DISTINCT vds.visitor_id) AS active_users,
            NOW(), NOW()
          FROM visitor_daily_statistics vds
          WHERE vds.event_date = ?::date
            AND (vds.project_id % ?) = ?
          GROUP BY vds.project_id, vds.platform
          ON CONFLICT (project_id, event_date, platform)
          DO UPDATE SET active_users = EXCLUDED.active_users,
                        updated_at   = NOW();
        SQL
      )

      ActiveRecord::Base.with_connection do |conn|
        conn.transaction do
          # 1s lock_timeout: this runs every 10 min via BackfillProjectDailyActiveUsersJob;
          # if a row is already locked (e.g. by a concurrent shard), fail fast and let
          # the next run pick it up rather than blocking a connection pool slot.
          conn.execute("SET LOCAL lock_timeout = '1s'")
          # 8min statement_timeout: the GROUP BY on visitor_daily_statistics can be slow
          # for high-traffic projects, but must finish within a single Sidekiq job cycle.
          conn.execute("SET LOCAL statement_timeout = '8min'")
          conn.execute(sql)
        end
      end
    end
  end
end
