namespace :backfill do
  desc "Backfill first_time_visitors in daily_project_metrics (all dates except today)"
  task first_time_visitors: :environment do
    yesterday   = Date.current - 1.day
    work_mem    = ENV.fetch("WORK_MEM", "256MB")
    timeout     = ENV.fetch("TIMEOUT", "600s")
    chunk_days  = ENV.fetch("CHUNK_DAYS", "90").to_i

    project_ids = DailyProjectMetric
                    .where("event_date <= ?", yesterday)
                    .distinct
                    .order(:project_id)
                    .pluck(:project_id)

    # Resume support: skip already-processed projects
    checkpoint_file = Rails.root.join("tmp/backfill_ftv_checkpoint.txt")
    last_done = checkpoint_file.exist? ? checkpoint_file.read.strip.to_i : 0
    remaining = project_ids.select { |id| id > last_done }

    puts "#{remaining.size} projects remaining (#{project_ids.size} total, resuming after #{last_done})"
    puts "Settings: work_mem=#{work_mem}, timeout=#{timeout}, chunk_days=#{chunk_days}"

    failed = []

    remaining.each_with_index do |project_id, idx|
      start = Time.current

      begin
        rows = fast_path(project_id, yesterday, work_mem, timeout)
        apply_results(project_id, yesterday, rows)

        checkpoint_file.write(project_id.to_s)
        elapsed = (Time.current - start).round(1)
        puts "[#{idx + 1}/#{remaining.size}] Project #{project_id}: #{rows.count} combos (#{elapsed}s)"
      rescue => e
        # Fast path failed (likely timeout on a huge project) — try chunked approach
        puts "[#{idx + 1}/#{remaining.size}] Project #{project_id}: fast path failed (#{e.message}), trying chunked..."

        begin
          start = Time.current
          rows = chunked_path(project_id, yesterday, chunk_days)
          apply_results(project_id, yesterday, rows)

          checkpoint_file.write(project_id.to_s)
          elapsed = (Time.current - start).round(1)
          puts "[#{idx + 1}/#{remaining.size}] Project #{project_id}: #{rows.count} combos via chunks (#{elapsed}s)"
        rescue => e2
          failed << project_id
          elapsed = (Time.current - start).round(1)
          puts "[#{idx + 1}/#{remaining.size}] Project #{project_id}: FAILED in #{elapsed}s — #{e2.message}"
        end
      end
    end

    checkpoint_file.delete if checkpoint_file.exist?
    if failed.any?
      puts "\nDone with #{failed.size} failures: #{failed.join(', ')}"
    else
      puts "\nDone!"
    end
  end
end

# Fast path: single CTE with MIN(event_date) GROUP BY.
# Works for most projects. Fails on monster projects (timeout/OOM).
def fast_path(project_id, yesterday, work_mem, timeout)
  conn = ActiveRecord::Base.connection
  conn.execute("SET work_mem = #{conn.quote(work_mem)}")
  conn.execute("SET statement_timeout = #{conn.quote(timeout)}")

  rows = conn.exec_query(
    ActiveRecord::Base.sanitize_sql_array([<<~SQL, project_id, yesterday])
      WITH first_visits AS (
        SELECT platform, visitor_id, MIN(event_date) AS first_date
        FROM visitor_daily_statistics
        WHERE project_id = ?
        GROUP BY visitor_id, platform
      )
      SELECT platform, first_date AS event_date, COUNT(*) AS ftv_count
      FROM first_visits
      WHERE first_date <= ?
      GROUP BY platform, first_date
    SQL
  )

  conn.execute("RESET work_mem")
  conn.execute("RESET statement_timeout")
  rows
ensure
  conn&.execute("RESET work_mem") rescue nil
  conn&.execute("RESET statement_timeout") rescue nil
end

# Chunked path for monster projects: build first-visit data incrementally
# using a temp table. Processes VDS in chronological date chunks so no
# single query ever scans all-time data.
#
# For each chunk: INSERT ON CONFLICT DO NOTHING — only the earliest
# occurrence (first chunk containing the visitor) gets inserted.
# Since we process chronologically, this gives correct MIN(event_date).
def chunked_path(project_id, yesterday, chunk_days)
  conn = ActiveRecord::Base.connection

  # Find the earliest VDS date for this project
  earliest = conn.exec_query(
    ActiveRecord::Base.sanitize_sql_array([
      "SELECT MIN(event_date) FROM visitor_daily_statistics WHERE project_id = ?",
      project_id
    ])
  ).first["min"]
  return [] unless earliest

  earliest = earliest.to_date

  conn.execute("DROP TABLE IF EXISTS _backfill_first_visit")
  conn.execute(<<~SQL)
    CREATE TEMP TABLE _backfill_first_visit (
      visitor_id bigint NOT NULL,
      platform varchar NOT NULL,
      first_date date NOT NULL,
      PRIMARY KEY (visitor_id, platform)
    )
  SQL

  # Process in chronological chunks — each chunk only scans a small date range
  chunk_start = earliest
  while chunk_start <= yesterday
    chunk_end = [chunk_start + chunk_days - 1, yesterday].min

    conn.exec_query(
      ActiveRecord::Base.sanitize_sql_array([<<~SQL, project_id, chunk_start, chunk_end])
        INSERT INTO _backfill_first_visit (visitor_id, platform, first_date)
        SELECT visitor_id, platform, MIN(event_date)
        FROM visitor_daily_statistics
        WHERE project_id = ? AND event_date BETWEEN ? AND ?
        GROUP BY visitor_id, platform
        ON CONFLICT (visitor_id, platform) DO NOTHING
      SQL
    )

    chunk_start = chunk_end + 1
  end

  # Aggregate from the temp table — small, fully in-memory
  rows = conn.exec_query(<<~SQL)
    SELECT platform, first_date AS event_date, COUNT(*) AS ftv_count
    FROM _backfill_first_visit
    GROUP BY platform, first_date
  SQL

  conn.execute("DROP TABLE IF EXISTS _backfill_first_visit")
  rows
rescue
  conn&.execute("DROP TABLE IF EXISTS _backfill_first_visit") rescue nil
  raise
end

# Apply computed first_time_visitors to DPM: zero then bulk update in a short transaction.
def apply_results(project_id, yesterday, rows)
  conn = ActiveRecord::Base.connection

  ActiveRecord::Base.transaction do
    DailyProjectMetric
      .where(project_id: project_id)
      .where("event_date <= ?", yesterday)
      .where.not(first_time_visitors: 0)
      .update_all(first_time_visitors: 0)

    rows.to_a.each_slice(500) do |batch|
      values = batch.map do |row|
        platform = conn.quote(row["platform"])
        date     = conn.quote(row["event_date"])
        count    = row["ftv_count"].to_i
        "(#{platform}, #{date}::date, #{count})"
      end.join(", ")

      conn.exec_update(
        ActiveRecord::Base.sanitize_sql_array([<<~SQL, project_id])
          UPDATE daily_project_metrics dpm
          SET first_time_visitors = v.ftv_count, updated_at = NOW()
          FROM (VALUES #{values}) AS v(platform, event_date, ftv_count)
          WHERE dpm.project_id = ?
            AND dpm.platform = v.platform
            AND dpm.event_date = v.event_date
        SQL
      )
    end
  end
end
