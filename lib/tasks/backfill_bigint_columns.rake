namespace :bigint do
  desc "Backfill visitor_daily_statistics.time_spent_big from time_spent"
  task backfill_vds: :environment do
    conn = ActiveRecord::Base.connection
    batch_size = 200_000

    min_id = conn.execute("SELECT MIN(id) FROM visitor_daily_statistics").first["min"]&.to_i
    max_id = conn.execute("SELECT MAX(id) FROM visitor_daily_statistics").first["max"]&.to_i
    abort("No rows to backfill in visitor_daily_statistics") unless min_id && max_id

    total = ((max_id - min_id + 1) / batch_size.to_f).ceil
    done = 0

    (min_id..max_id).step(batch_size) do |start_id|
      end_id = start_id + batch_size - 1
      begin
        conn.execute(<<~SQL)
          UPDATE visitor_daily_statistics
          SET time_spent_big = time_spent
          WHERE id BETWEEN #{start_id} AND #{end_id}
            AND time_spent_big IS DISTINCT FROM time_spent
        SQL
      rescue ActiveRecord::RecordNotUnique
        puts "[VDS] Skipped batch #{done + 1} (concurrent write conflict, trigger has it covered)"
      end
      done += 1
      puts "[VDS] Backfilled batch #{done}/#{total} (id #{start_id}..#{end_id})" if done % 100 == 0
      sleep(2)
    end
    puts "[VDS] Backfill complete: #{done} batches"
  end

  desc "Backfill events.engagement_time_big from engagement_time"
  task backfill_events: :environment do
    conn = ActiveRecord::Base.connection
    batch_size = 200_000

    min_id = conn.execute("SELECT MIN(id) FROM events").first["min"]&.to_i
    max_id = conn.execute("SELECT MAX(id) FROM events").first["max"]&.to_i
    abort("No rows to backfill in events") unless min_id && max_id

    total = ((max_id - min_id + 1) / batch_size.to_f).ceil
    done = 0

    (min_id..max_id).step(batch_size) do |start_id|
      end_id = start_id + batch_size - 1
      begin
        conn.execute(<<~SQL)
          UPDATE events
          SET engagement_time_big = engagement_time
          WHERE id BETWEEN #{start_id} AND #{end_id}
            AND engagement_time IS NOT NULL
            AND engagement_time_big IS DISTINCT FROM engagement_time
        SQL
      rescue ActiveRecord::RecordNotUnique
        puts "[EVENTS] Skipped batch #{done + 1} (concurrent write conflict, trigger has it covered)"
      end
      done += 1
      puts "[EVENTS] Backfilled batch #{done}/#{total} (id #{start_id}..#{end_id})" if done % 100 == 0
      sleep(2)
    end
    puts "[EVENTS] Backfill complete: #{done} batches"
  end

  desc "Backfill both tables"
  task backfill_all: [:backfill_vds, :backfill_events]

  desc "Verify backfill: count mismatched rows"
  task verify: :environment do
    conn = ActiveRecord::Base.connection

    vds_mismatches = conn.execute(<<~SQL).first["count"]
      SELECT COUNT(*) FROM visitor_daily_statistics
      WHERE time_spent_big IS DISTINCT FROM time_spent
    SQL

    events_mismatches = conn.execute(<<~SQL).first["count"]
      SELECT COUNT(*) FROM events
      WHERE engagement_time IS NOT NULL
        AND engagement_time_big IS DISTINCT FROM engagement_time
    SQL

    puts "visitor_daily_statistics mismatches: #{vds_mismatches}"
    puts "events mismatches: #{events_mismatches}"

    if vds_mismatches.to_i == 0 && events_mismatches.to_i == 0
      puts "All good — safe to run the swap migration."
    else
      puts "WARNING: backfill not complete, do NOT run the swap migration yet."
    end
  end
end
