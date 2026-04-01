namespace :dashboard_optimization do
  desc "Test: backfill first_time_visitors for a project, compare old vs new returning users"
  task test: :environment do
    # --- Configuration ---
    PROJECT_ID = (ENV["PROJECT_ID"] || 637).to_i
    DAYS_BACK  = (ENV["DAYS_BACK"] || 30).to_i
    end_date   = Date.today
    start_date = end_date - DAYS_BACK.days

    puts "=" * 70
    puts "Dashboard Optimization Test"
    puts "Project: #{PROJECT_ID} | Range: #{start_date} to #{end_date} (#{DAYS_BACK} days)"
    puts "=" * 70

    # --- Step 1: Backfill first_time_visitors for a few days ---
    backfill_start = ENV["BACKFILL_START"]&.to_date || start_date - 60.days
    backfill_end   = ENV["BACKFILL_END"]&.to_date || end_date

    puts "\n[1/4] Backfilling DPM for #{backfill_start} to #{backfill_end}..."
    t0 = Time.now
    DailyProjectMetricsBackfillService.call(start_date: backfill_start, end_date: backfill_end)
    puts "  Done in #{(Time.now - t0).round(1)}s"

    ftv_count = DailyProjectMetric.where(project_id: PROJECT_ID)
                  .where(event_date: start_date..end_date)
                  .where("first_time_visitors > 0").count
    puts "  DPM rows with first_time_visitors > 0 in range: #{ftv_count}"

    # --- Step 2: Old method — live EXISTS query for returning users ---
    puts "\n[2/4] Running OLD method (live EXISTS query)..."
    t0 = Time.now
    old_returning = old_returning_visitors(PROJECT_ID, start_date, end_date)
    old_time = Time.now - t0
    puts "  Old returning users: #{old_returning} (#{old_time.round(3)}s)"

    # --- Step 3: New method — total - first_time_visitors from DPM ---
    puts "\n[3/4] Running NEW method (total - SUM(first_time_visitors))..."
    t0 = Time.now
    total_users = unique_visitors(PROJECT_ID, start_date, end_date)
    total_time = Time.now - t0

    ftv_sum = DailyProjectMetric
                .where(project_id: PROJECT_ID, event_date: start_date..end_date)
                .sum(:first_time_visitors)
    new_returning = [total_users - ftv_sum, 0].max
    new_time = total_time # DPM sum is negligible
    puts "  Total unique visitors: #{total_users} (#{total_time.round(3)}s)"
    puts "  SUM(first_time_visitors): #{ftv_sum}"
    puts "  New returning users: #{new_returning} (#{new_time.round(3)}s)"

    # --- Step 4: Compare ---
    puts "\n[4/4] Comparison"
    puts "-" * 50
    diff = old_returning - new_returning
    match = diff == 0

    puts "  Old (EXISTS):       #{old_returning}"
    puts "  New (total - ftv):  #{new_returning}"
    puts "  Difference:         #{diff}"
    puts "  Match:              #{match ? 'YES' : 'NO'}"
    puts "  Old query time:     #{old_time.round(3)}s"
    puts "  New query time:     #{new_time.round(3)}s"
    if old_time > 0
      puts "  Speedup:            #{(old_time / [new_time, 0.001].max).round(1)}x"
    end

    unless match
      puts "\n  NOTE: Mismatch is expected when DPM was not backfilled from the"
      puts "  very beginning of the project's data. The new method counts a visitor"
      puts "  as 'first time' relative to ALL historical VDS, while the old method"
      puts "  only looks at VDS before the range start."
      puts "  To get an exact match, backfill from the project's earliest VDS date."
    end

    # --- Step 5: EXPLAIN ANALYZE on the DISTINCT query with new index ---
    puts "\n[BONUS] EXPLAIN ANALYZE for unique_visitors query with new index:"
    explain_sql = ActiveRecord::Base.send(:sanitize_sql_array, [
      "EXPLAIN ANALYZE SELECT COUNT(DISTINCT visitor_id) FROM visitor_daily_statistics WHERE project_id = ? AND event_date BETWEEN ? AND ?",
      PROJECT_ID, start_date, end_date
    ])
    rows = ActiveRecord::Base.connection.exec_query(explain_sql).to_a
    rows.each { |r| puts "  #{r['QUERY PLAN']}" }

    puts "\n" + "=" * 70
    puts "Test complete."
    puts "=" * 70
  end

  desc "Quick: run DashboardMetrics for a project and time it"
  task benchmark: :environment do
    PROJECT_ID = (ENV["PROJECT_ID"] || 637).to_i
    DAYS_BACK  = (ENV["DAYS_BACK"] || 30).to_i
    end_date   = Date.today
    start_date = end_date - DAYS_BACK.days

    puts "Benchmarking DashboardMetrics.call for project #{PROJECT_ID}..."
    puts "Range: #{start_date} to #{end_date}"

    t0 = Time.now
    result = DashboardMetrics.call(
      project_id: PROJECT_ID,
      start_time: start_date,
      end_time: end_date
    )
    elapsed = Time.now - t0

    puts "\nCurrent period:"
    result[:current].each { |k, v| puts "  #{k}: #{v}" }
    puts "\nPrevious period:"
    result[:previous].each { |k, v| puts "  #{k}: #{v}" }
    puts "\nTotal time: #{elapsed.round(3)}s"
  end
end

def old_returning_visitors(project_id, range_start, range_end)
  sql = ActiveRecord::Base.send(
    :sanitize_sql_array,
    [<<~SQL, project_id, range_start, range_end, range_start]
      SELECT COUNT(DISTINCT current_vds.visitor_id)
      FROM visitor_daily_statistics current_vds
      WHERE current_vds.project_id = ?
        AND current_vds.event_date BETWEEN ? AND ?
        AND EXISTS (
          SELECT 1 FROM visitor_daily_statistics prev
          WHERE prev.project_id = current_vds.project_id
            AND prev.platform = current_vds.platform
            AND prev.visitor_id = current_vds.visitor_id
            AND prev.event_date < ?
        )
    SQL
  )
  ActiveRecord::Base.connection.exec_query(sql).first["count"].to_i
end

def unique_visitors(project_id, range_start, range_end)
  VisitorDailyStatistic
    .where(project_id: project_id, event_date: range_start..range_end)
    .distinct.count(:visitor_id)
end
