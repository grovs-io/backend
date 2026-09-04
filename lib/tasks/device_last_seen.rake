# frozen_string_literal: true

namespace :device_last_seen do
  desc "Backfill device_last_seens from ClickHouse events. Resumable: CURSOR=<project_id,device_id>. " \
       "BATCH_SIZE=<n> (default 50000), MONTHS=<n> lookback (default 18), SLEEP=<s> between batches. " \
       "Safe against live stamps (GREATEST upsert). Idempotent; restart refreshes the staging aggregate."
  task backfill: :environment do
    abort "ClickHouse reads disabled" unless Clickhouse.read_enabled?

    batch_size = Integer(ENV.fetch("BATCH_SIZE", 5_000))
    months     = Integer(ENV.fetch("MONTHS", 18))
    # CURSOR resumes as "project_id,device_id".
    cursor_p, cursor_d = ENV.fetch("CURSOR", "0,0").split(",").map { |v| Integer(v) }
    staging    = "device_last_seen_backfill"

    if cursor_p.zero? && cursor_d.zero?
      puts "Aggregating last-seen per project-device into #{staging} (lookback #{months} months)..."
      Clickhouse.with do |conn|
        conn.execute("DROP TABLE IF EXISTS #{staging}")
        conn.execute(<<~SQL)
          CREATE TABLE #{staging} ENGINE = MergeTree ORDER BY (project_id, device_id) AS
          SELECT project_id, device_id, max(created_at) AS last_seen_at
          FROM events
          WHERE device_id > 0 AND created_at >= now() - INTERVAL #{months} MONTH AND created_at <= now()
          GROUP BY project_id, device_id
          SETTINGS max_threads = 8, max_execution_time = 600,
                   max_memory_usage = 8000000000, max_bytes_before_external_group_by = 2000000000
        SQL
      end
    end

    total = Clickhouse.with { |conn| conn.select_value("SELECT count() FROM #{staging}") }.to_i
    puts "Staging holds #{total} project-device pairs. Applying from cursor #{cursor_p},#{cursor_d}..."

    applied = 0
    loop do
      rows = Clickhouse.with do |conn|
        conn.select_all(
          "SELECT project_id, device_id, toString(last_seen_at) AS last_seen_at FROM #{staging} " \
          "WHERE (project_id, device_id) > (#{cursor_p}, #{cursor_d}) " \
          "ORDER BY project_id, device_id LIMIT #{batch_size}"
        )
      end.to_a
      break if rows.empty?

      now = Time.current
      pg_rows = rows.map do |r|
        { project_id: r["project_id"].to_i, device_id: r["device_id"].to_i,
          last_seen_at: Time.zone.parse(r["last_seen_at"]), created_at: now, updated_at: now }
      end
      # Same GREATEST upsert as the live stamp, so backfill and stamping can overlap safely.
      DeviceLastSeen.upsert_all(
        pg_rows.sort_by { |r| [r[:project_id], r[:device_id]] },
        unique_by: %i[project_id device_id],
        returning: false,
        on_duplicate: Arel.sql(
          "last_seen_at = GREATEST(device_last_seens.last_seen_at, excluded.last_seen_at), " \
          "updated_at = excluded.updated_at"
        )
      )

      cursor_p = rows.last["project_id"].to_i
      cursor_d = rows.last["device_id"].to_i
      applied += rows.size
      puts "  applied #{applied}/#{total} (cursor #{cursor_p},#{cursor_d})"
      sleep Float(ENV.fetch("SLEEP", 0.1))
    end

    Clickhouse.with { |conn| conn.execute("DROP TABLE IF EXISTS #{staging}") }
    puts "DONE. #{applied} devices backfilled; PG rows: #{DeviceLastSeen.count}"
  end
end
