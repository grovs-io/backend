# frozen_string_literal: true

require_relative '../clickhouse/migration'
require_relative '../clickhouse/schema_migration'
require_relative '../clickhouse/migrator'

RESERVED_DATABASES = %w[default system information_schema INFORMATION_SCHEMA].freeze

def validated_database_name
  name = Clickhouse.default_database
  unless name.match?(/\A[a-zA-Z0-9_]+\z/)
    abort "Invalid ClickHouse database name: #{name.inspect} (must be alphanumeric/underscore only)"
  end
  if RESERVED_DATABASES.include?(name)
    abort "Refusing to operate on reserved database: #{name}"
  end
  name
end

namespace :clickhouse do
  desc 'Create ClickHouse database'
  task create: :environment do
    db = validated_database_name
    admin = Clickhouse.build_connection(database: 'default')
    admin.execute("CREATE DATABASE IF NOT EXISTS `#{db}`")
    puts "Created database: #{db}"
  end

  desc 'Run pending ClickHouse migrations'
  task migrate: :environment do
    Clickhouse::Migrator.new.migrate
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
         Net::OpenTimeout, Net::ReadTimeout, SocketError, IOError => e
    if Clickhouse.enabled? || Clickhouse.read_enabled?
      # CH is supposed to be active — fail loud so deploy stops.
      raise
    else
      # CH not enabled — warn but don't block deploy.
      warn "⚠ ClickHouse migrations skipped (not reachable: #{e.class}). " \
           "Set CLICKHOUSE_WRITE_ENABLED=true when CH is ready."
    end
  end

  desc 'Backfill idx_device on existing event parts (deliberately not run by migrate — heavy mutation)'
  task materialize_device_index: :environment do
    Clickhouse.with { |conn| conn.execute("ALTER TABLE events MATERIALIZE INDEX idx_device") }
    puts "Mutation submitted. Track it with:"
    puts "  SELECT is_done, parts_to_do, latest_fail_reason FROM system.mutations " \
         "WHERE database = currentDatabase() AND table = 'events' ORDER BY create_time DESC LIMIT 3"
  end

  desc 'Create database and run all migrations'
  task setup: :environment do
    Rake::Task['clickhouse:create'].invoke
    Rake::Task['clickhouse:migrate'].invoke
  end

  desc 'Drop ClickHouse database'
  task drop: :environment do
    if Rails.env.production? && ENV['DISABLE_DATABASE_ENVIRONMENT_CHECK'] != '1'
      abort "Refusing to drop production ClickHouse database. " \
            "Set DISABLE_DATABASE_ENVIRONMENT_CHECK=1 to override."
    end

    db = validated_database_name
    admin = Clickhouse.build_connection(database: 'default')
    admin.execute("DROP DATABASE IF EXISTS `#{db}`")
    puts "Dropped database: #{db}"
  end

  desc 'Drop and recreate ClickHouse database with all tables'
  task reset: :environment do
    Rake::Task['clickhouse:drop'].invoke
    Rake::Task['clickhouse:create'].invoke
    Rake::Task['clickhouse:migrate'].invoke
  end

  desc 'Rebuild session_events and session_summary from events (truncate + re-sessionize)'
  task rebuild_sessions: :environment do
    days = (ENV['DAYS'] || 30).to_i
    ttl = Integer(ENV.fetch('LOCK_TTL_SECONDS', 6 * 60 * 60))

    # Partitions that already hold derived rows. The truncate below is GLOBAL, so anything
    # outside the DAYS range must be rebuilt too or it keeps rows whose source is gone.
    existing_rows = Clickhouse.with do |conn|
      conn.select_all("SELECT DISTINCT toYYYYMM(event_date) AS p FROM link_session_daily")
    end
    existing = existing_rows.map { |r| r['p'].to_i }

    puts "Truncating session_events and session_summary..."
    Clickhouse.with do |conn|
      conn.execute('TRUNCATE TABLE IF EXISTS session_events')
      conn.execute('TRUNCATE TABLE IF EXISTS session_summary')
    end
    puts "Running SessionBuildJob with lookback_days: #{days} (lock ttl #{ttl}s)..."
    job = SessionBuildJob.new
    job.defer_open_sessions = false # settled history: nothing left to wait for
    failed = job.perform(lookback_days: days, lock_ttl: ttl)

    # The tables are already truncated at this point, so a run that never happened would
    # otherwise publish empty rollups over real data.
    if failed == :skipped
      abort "SessionBuildJob SKIPPED (another run holds the lock) — session tables are now " \
            "EMPTY. Wait for the scheduled job to finish, then re-run."
    end
    abort "ClickHouse writes/reads disabled — session tables are now EMPTY." if failed == :disabled
    Clickhouse.with do |conn|
      se = conn.select_value('SELECT count() FROM session_events')
      ss = conn.select_value('SELECT count() FROM session_summary')
      puts "Done. session_events: #{se} rows, session_summary: #{ss} rows"
    end

    # link_session_daily is the only rollup fed by session_summary, so rebuild exactly it
    # over exactly the range just rebuilt. Marking the partitions dirty instead would drag
    # every other rollup through a full recompute of those months.
    # Rebuilding over a partly-sessionized range would persist zeros as authoritative.
    if failed.present?
      abort "Sessionization FAILED for #{failed.size} project(s): #{failed.inspect}. " \
            "link_session_daily NOT rebuilt — fix and re-run."
    end

    from = [ClickhouseRollupRebuildService.partition_for(days.days.ago.to_date).to_i,
            *existing].min
    to = [ClickhouseRollupRebuildService.partition_for(Date.current).to_i, *existing].max
    puts "Rebuilding link_session_daily for partitions #{from}..#{to}..."
    begin
      # strict/fail_on_skip: this is a one-shot operator repair — a lock skip or a failed
      # partition must abort, not print "Done." over an incomplete rollup.
      ClickhouseRollupRebuildService.rebuild_partition_range(
        from, to, rollups: %i[link_sessions], strict: true, fail_on_skip: true
      )
    rescue RuntimeError => e
      abort "Rebuild FAILED — link_session_daily is INCOMPLETE: #{e.message}"
    end
    puts "Done."
  end

  desc 'Rebuild exact CH rollups from canonical: watermark window + out-of-window dirty partitions'
  task rebuild_rollups: :environment do
    months = (ENV['WATERMARK_MONTHS'] || 1).to_i
    puts "Rebuilding CH rollups (watermark_months: #{months})..."
    ClickhouseRollupRebuildService.rebuild_all_dirty(watermark_months: months)
    ClickhouseRollupRebuildService.rebuild_stale_dirty(watermark_months: months)
    puts "Done."
  end

  desc 'Deterministically rebuild CH rollups for an inclusive YYYYMM range, ' \
       'ignoring dirty-tracking (Phase 6 backfill). RANGE=YYYYMM-YYYYMM [ROLLUP=project|link|visitor]'
  task rebuild_rollups_range: :environment do
    range = ENV.fetch('RANGE')
    from, to = range.split('-', 2)
    abort "RANGE must be YYYYMM-YYYYMM" if to.nil?
    opts = ENV['ROLLUP'] ? { rollups: [ENV['ROLLUP'].to_sym] } : {}
    puts "Rebuilding rollups #{ENV['ROLLUP'] || 'ALL'} for partitions #{from}..#{to}..."
    begin
      done = ClickhouseRollupRebuildService.rebuild_partition_range(from, to, strict: true, fail_on_skip: true, **opts)
    rescue RuntimeError => e
      abort "Rebuild FAILED — rollups are INCOMPLETE: #{e.message}"
    end
    puts "Done. Partitions: #{done.inspect}"
  end

  desc 'Report per-metric parity between a CH rollup and its PG stat table ' \
       '(ROLLUP=project|link|visitor PROJECT_ID=.. START=YYYY-MM-DD END=YYYY-MM-DD)'
  task rollup_parity: :environment do
    rollup = (ENV['ROLLUP'] || 'visitor').to_sym
    project_id = Integer(ENV.fetch('PROJECT_ID'))
    start_date = Date.parse(ENV.fetch('START'))
    end_date = Date.parse(ENV.fetch('END'))

    results = Billing::ClickhouseParityCheck.rollup_parity(
      rollup: rollup, project_id: project_id, start_date: start_date, end_date: end_date
    )

    puts "Parity #{rollup} project=#{project_id} #{start_date}..#{end_date}"
    results.each do |metric, r|
      puts format("  %<metric>-14s pg=%<pg>-10s ch=%<ch>-10s delta=%<delta>-8s %<status>s",
        metric: metric, pg: r.postgres_count, ch: r.clickhouse_count.inspect,
        delta: r.delta.inspect, status: r.status)
    end
    puts "NOT COVERED by this rollup (NOT a complete replacement):"
    results.uncovered.each { |col, reason| puts "  #{col}: #{reason}" }
    puts "NOTE: countable metrics compare RANGE TOTALS (organic_users is per-day); run START=END for daily checks"
    mismatches = results.values.count { |r| !r.match? }
    # Gate task: nonzero exit so deploy scripts can enforce parity before flag-on
    abort "#{mismatches} metric(s) mismatched" unless mismatches.zero?
    puts "ALL CHECKED METRICS MATCH (see NOT COVERED above)"
  end

  desc 'Phase 6: one-time PG->CH history backfill into events + rollup rebuild. ' \
       'START=YYYY-MM-DD END=YYYY-MM-DD [PROJECT_ID=..] [REBUILD=false]'
  task backfill_history: :environment do
    start_date = Date.parse(ENV.fetch('START'))
    end_date = Date.parse(ENV.fetch('END'))
    project_id = ENV['PROJECT_ID'] && Integer(ENV['PROJECT_ID'])
    rebuild = ENV.fetch('REBUILD', 'true') != 'false'

    puts "Backfilling canonical from PG events #{start_date}..#{end_date}" \
         "#{project_id ? " project=#{project_id}" : ''} (rebuild: #{rebuild})..."
    result = ClickhouseHistoryBackfillService.backfill(
      start_date: start_date, end_date: end_date, project_id: project_id, rebuild: rebuild
    )
    skipped_missing = result.skipped[:missing_device].to_i
    puts "Done. read: #{result.events_read}, inserted: #{result.rows_inserted}, " \
         "skipped(missing_device): #{skipped_missing}, batches: #{result.batches}, " \
         "partitions: #{result.partitions.inspect}"
  end

  desc 'Phase 6 GO/NO-GO parity gate: rollup + attribution parity for a project/range. ' \
       'PROJECT_ID=.. START=YYYY-MM-DD END=YYYY-MM-DD. Exits non-zero on FAIL.'
  task parity_gate: :environment do
    project_id = Integer(ENV.fetch('PROJECT_ID'))
    start_date = Date.parse(ENV.fetch('START'))
    end_date = Date.parse(ENV.fetch('END'))

    gate = Billing::ClickhouseParityCheck.gate(
      project_id: project_id, start_date: start_date, end_date: end_date
    )

    puts "Parity gate project=#{project_id} #{start_date}..#{end_date}"
    gate.reports.each do |name, report|
      puts "  [#{name}]"
      report.covered.each do |metric, r|
        flag = case r.status
               when 'match' then 'OK '
               when 'accepted_redelivery_delta' then '~~ '
               when 'clickhouse_unavailable' then '?? '
               else 'XX '
               end
        puts format("    %<flag>s%<metric>-16s pg=%<pg>-10s ch=%<ch>-10s delta=%<delta>s",
          flag: flag, metric: metric, pg: r.postgres_count,
          ch: r.clickhouse_count.inspect, delta: r.delta.inspect)
      end
    end
    sc = gate.session_coverage
    case sc
    when nil then puts "\n  [session coverage] UNAVAILABLE — could not read link_session_daily"
    when :not_applicable then puts "\n  [session coverage] n/a — no link activity in range"
    else
      flag = sc[:session_links].zero? ? 'XX ' : 'OK '
      puts format("\n  [session coverage] %<flag>s links_with_activity=%<a>d links_with_sessions=%<s>d",
        flag: flag, a: sc[:active_links], s: sc[:session_links])
      if sc[:session_links].zero?
        puts "    link_session_daily is EMPTY for this range — avg_engagement_time would serve 0.0. " \
             "Run clickhouse:rebuild_sessions."
      end
    end

    cov = gate.coverage
    if cov.nil?
      puts "\n  [acquisition coverage] UNAVAILABLE — could not verify visitor_acquisition completeness"
    else
      flag = cov.complete? ? 'OK ' : 'XX '
      puts format("\n  [acquisition coverage] %<flag>s acquisition=%<acq>d events=%<ev>d missing=%<miss>d (%<pct>.2f%%)",
        flag: flag, acq: cov.acquisition_visitors, ev: cov.event_visitors,
        miss: cov.missing, pct: cov.percent_missing)
      puts "    visitor_acquisition is INCOMPLETE — rebuild it before trusting install/first attribution." unless cov.complete?
    end

    puts "NOT COVERED (still on Postgres / separate definition — NOT a complete replacement):"
    gate.uncovered.each { |key, reason| puts "  #{key}: #{reason}" }

    accepted = gate.accepted_deltas
    if accepted.any?
      puts "\n#{'!' * 76}"
      puts "ACCEPTED REDELIVERY DELTAS — CH is BELOW legacy PG here. This is NOT exact parity;"
      puts "it is a deliberately accepted delta (content-hash dedup of client retransmits)."
      accepted.each do |name, metric, r|
        pct = r.percent_delta ? format('%.2f%%', r.percent_delta) : 'n/a'
        puts "  #{name}.#{metric}: pg=#{r.postgres_count} ch=#{r.clickhouse_count} delta=#{r.delta} (#{pct})"
      end
      puts '!' * 76
    end

    print_unavailable = lambda do
      gate.unavailable.each do |name, metric, _r|
        puts(metric == :oracle ? "  #{name}: query failed — nothing compared" : "  #{name}.#{metric}: unavailable")
      end
      puts "  acquisition coverage: unreadable" if cov.nil?
    end

    # Branch on gate.status so the CLI can never disagree with the gate's own verdict.
    case gate.status
    when 'inconclusive'
      puts "\nRESULT: INCONCLUSIVE — the check DID NOT RUN (this is not a divergence):"
      if gate.unavailable.any? || cov.nil?
        print_unavailable.call
        puts "  Oracle checks: raise CLICKHOUSE_HTTP_READ_TIMEOUT and CLICKHOUSE_ORACLE_MAX_MEMORY_BYTES " \
             "(keep CLICKHOUSE_ORACLE_MAX_BYTES_BEFORE_EXTERNAL_GROUP_BY at ~1/4 of it)."
        puts "  Coverage: raise CLICKHOUSE_COVERAGE_MAX_MEMORY_BYTES / " \
             "CLICKHOUSE_COVERAGE_MAX_EXECUTION_SECONDS. Then retry."
        abort 'Parity gate INCONCLUSIVE — fix the oracle before reading this result; do NOT flip any read flag.'
      end
      puts "  no data on either side for this range; nothing to compare."
      abort 'Parity gate INCONCLUSIVE — backfill data first; do NOT flip any read flag.'
    when 'pass'
      msg = if accepted.any?
              "with #{accepted.size} ACCEPTED redelivery delta(s) above — NOT exact parity"
            else
              "every covered metric/bucket matches the trusted oracle exactly"
            end
      puts "\nRESULT: PASS — #{msg}."
    else
      reasons = []
      reasons << "#{gate.mismatches.size} covered metric(s) diverged" if gate.mismatches.any?
      reasons << "visitor_acquisition incomplete (#{cov.missing} visitors missing)" if cov && !cov.complete?
      puts "\nRESULT: FAIL — #{reasons.join('; ')}:"
      gate.mismatches.each { |name, metric, r| puts "  #{name}.#{metric}: delta=#{r.delta.inspect} (#{r.status})" }
      if gate.unavailable.any? || cov.nil?
        puts "  (some checks did not run — they are NOT the reason for this FAIL:)"
        print_unavailable.call
      end
      abort 'Parity gate FAILED — do NOT flip any read flag.'
    end
  end

  desc 'Truncate all ClickHouse tables (skips materialized views and schema_migrations)'
  task truncate: :environment do
    Clickhouse.with do |conn|
      tables = conn.select_all(
        "SELECT name FROM system.tables WHERE database = currentDatabase() AND engine NOT LIKE '%View%'"
      )
      tables.each do |row|
        table = row['name']
        next if table == 'schema_migrations'
        conn.execute("TRUNCATE TABLE IF EXISTS `#{table}`")
        puts "Truncated: #{table}"
      end
    end
  end

  desc 'Calibrate archive import throughput. INSERTS a sample into events ' \
       '(idempotent, no manifest advance) — not a dry run. ARCHIVE_DIR=.. ' \
       '[FILE_LIST=.. PROJECT_IDS=.. FROM=YYYY-MM-DD TO=YYYY-MM-DD SAMPLE=20]'
  task import_archive_calibrate: :environment do
    # Calibration INSERTS a sample into events; same overlap risk as the real import.
    if Clickhouse.read_enabled? && ENV['I_KNOW'] != '1'
      abort "Refusing: CLICKHOUSE_READ_ENABLED=true — calibration writes archive content-hash rows that " \
            "can't dedup against live UUIDs. Run with reads OFF (or set TO=, I_KNOW=1)."
    end
    stats = ClickhouseArchiveImportService.calibrate(
      archive_dir: ENV.fetch('ARCHIVE_DIR'), file_list: ENV['FILE_LIST'],
      from: ENV['FROM'], to: ENV['TO'], sample: Integer(ENV.fetch('SAMPLE', '20')),
      project_ids: ENV['PROJECT_IDS']&.split(',')&.map { |x| Integer(x.strip) }&.to_set
    )
    rate = stats[:rows_per_sec]
    puts format("Calibration: %<files>d files, %<rows>d rows in %<secs>.1fs = %<rate>d rows/sec (single stream)",
      files: stats[:files], rows: stats[:events_read], secs: stats[:seconds], rate: rate)
    puts "(inserted the sample into events — idempotent, no manifest advance)"
    puts "skipped: #{stats[:skipped].inspect}"
    next unless rate.positive?

    total = 1_500_000_000
    %w[1 4 8 16].each do |w|
      puts format("  ETA @ %<w>2s workers (linear): %<h>.1f h", w: w, h: total / (rate * w.to_i) / 3600.0)
    end
    puts "(ETA assumes linear scaling; real scaling caps where PG/CH/CPU saturate.)"
  end

  desc 'Import ONE worker shard of the gzip archive into events (resumable). ' \
       'TO=YYYY-MM-DD is REQUIRED (< live dual-write start) to avoid keyspace overlap. ' \
       'Run N of these in parallel via import_archive.sh. ARCHIVE_DIR=.. MANIFEST_DIR=.. ' \
       'TO=.. [FILE_LIST=.. WORKER_INDEX=0 WORKER_COUNT=1 PROJECT_IDS=.. FROM=.. ' \
       'ARCHIVE_IMPORT_BATCH_SIZE=20000 ALLOW_UNBOUNDED=1]'
  task import_archive: :environment do
    if Clickhouse.read_enabled? && ENV['I_KNOW'] != '1'
      abort "Refusing: CLICKHOUSE_READ_ENABLED=true during import — a late ReplacingMergeTree row " \
            "could overwrite a fresher live row (runbook: reads OFF). Set I_KNOW=1 to override."
    end

    # Historical AND live rows now key by the SAME deterministic content hash (one keyspace), so an
    # overlap dedups rather than double-counts. TO= is still required to SCOPE what gets imported and
    # keep the run bounded/resumable — not to prevent double-count. ALLOW_UNBOUNDED=1 to override.
    if ENV['TO'].to_s.strip.empty? && ENV['ALLOW_UNBOUNDED'] != '1'
      abort "Refusing: set TO=YYYY-MM-DD strictly BEFORE the live dual-write start so the import can't " \
            "overlap the live UUID keyspace and double-count events. " \
            "Override with ALLOW_UNBOUNDED=1 only if you have proven the windows are disjoint."
    end

    result = ClickhouseArchiveImportService.import(
      archive_dir: ENV.fetch('ARCHIVE_DIR'), manifest_dir: ENV.fetch('MANIFEST_DIR'),
      file_list: ENV['FILE_LIST'], from: ENV['FROM'], to: ENV['TO'],
      worker_index: Integer(ENV.fetch('WORKER_INDEX', '0')),
      worker_count: Integer(ENV.fetch('WORKER_COUNT', '1')),
      project_ids: ENV['PROJECT_IDS']&.split(',')&.map { |x| Integer(x.strip) }&.to_set
    )
    puts "[w#{ENV.fetch('WORKER_INDEX', '0')}] Done. imported: #{result.files}, failed: #{result.failed_files}, " \
         "read: #{result.events_read}, inserted: #{result.rows_inserted}, " \
         "skipped: #{result.skipped.inspect}"
  end

  desc 'Rebuild all rollups across the partitions present in events ' \
       '(run once after all import_archive workers finish). REPLACE PARTITION is GLOBAL ' \
       '(all projects per month) — production requires ALL_PROJECTS_CONFIRMED=1.'
  task import_archive_rebuild: :environment do
    # REPLACE PARTITION rebuilds the whole month for EVERY project from current canonical;
    # a partial (project-filtered) canonical would wipe the rest. Guard prod.
    if Rails.env.production? && ENV['ALL_PROJECTS_CONFIRMED'] != '1'
      abort "Refusing: rebuild is global per partition and would wipe rollups for any project not in " \
            "canonical. Set ALL_PROJECTS_CONFIRMED=1 once the full all-projects import is verified."
    end

    parts = Clickhouse.with do |conn|
      conn.select_all(
        "SELECT min(toYYYYMM(created_at)) AS lo, max(toYYYYMM(created_at)) AS hi FROM events"
      ).first
    end
    abort "events is empty — nothing to rebuild." unless parts && parts['lo'].to_i.positive?

    puts "Rebuilding rollups for partitions #{parts['lo']}..#{parts['hi']}..."
    begin
      # strict: any (rollup, partition) failure raises so we NEVER print a green
      # "Done." over incomplete rollups on the cutover path.
      ClickhouseRollupRebuildService.rebuild_partition_range(
        parts['lo'].to_s, parts['hi'].to_s,
        strict: true, fail_on_skip: true
      )
    rescue StandardError => e
      abort "Rebuild FAILED — rollups are INCOMPLETE, DO NOT cut over: #{e.message}"
    end
    puts "Done."
  end

  desc 'DEV/STAGING smoke: reset CH, backfill from the PG events table, then parity. ' \
       'PROJECT_ID=.. START=YYYY-MM-DD END=YYYY-MM-DD [SKIP_RESET=true]. Refuses on production. ' \
       'NOTE: PG-events path only — NOT the cold-storage archive-import parity story (see import_archive*).'
  task verify_from_pg: :environment do
    abort "Refusing to reset/backfill on PRODUCTION (this drops the CH database)." if Rails.env.production?

    project_id = Integer(ENV.fetch('PROJECT_ID'))
    start_date = Date.parse(ENV.fetch('START'))
    end_date   = Date.parse(ENV.fetch('END'))

    # This verification both WRITES (backfill) and READS (parity) ClickHouse, so
    # force both flags on for the run regardless of the deployed env config.
    Rails.application.config.clickhouse_write_enabled = true
    Rails.application.config.clickhouse_read_enabled  = true

    unless ENV['SKIP_RESET'] == 'true'
      puts "== 1/3 Reset ClickHouse (drop + recreate + migrate → single `events` table) =="
      Rake::Task['clickhouse:reset'].invoke
    end

    puts "\n== 2/3 Backfill from PG events #{start_date}..#{end_date} project=#{project_id} =="
    result = ClickhouseHistoryBackfillService.backfill(
      start_date: start_date, end_date: end_date, project_id: project_id, rebuild: true
    )
    puts "   read=#{result.events_read} inserted=#{result.rows_inserted} " \
         "skipped=#{result.skipped.inspect} batches=#{result.batches} partitions=#{result.partitions.inspect}"

    puts "\n== Raw event-count sanity (PG vs CH FINAL) =="
    pg_events = Event.where(project_id: project_id,
                            created_at: start_date.beginning_of_day..end_date.end_of_day).count
    ch_events = Clickhouse.with do |c|
      c.select_value(
        "SELECT count() FROM events FINAL WHERE project_id = #{project_id} " \
        "AND toDate(created_at) BETWEEN toDate('#{start_date}') AND toDate('#{end_date}')"
      )
    end.to_i
    puts "   PG=#{pg_events}  CH(FINAL)=#{ch_events}  delta=#{ch_events - pg_events} " \
         "(expect ~0; CH may be slightly lower — skipped-device events + dedup)"

    puts "\n== 3/3 Parity gate (authoritative GO/NO-GO — aborts non-zero on FAIL) =="
    Rake::Task['clickhouse:parity_gate'].invoke
  end

  desc 'Sync visitor identities (sdk_identifier, uuid) from Postgres into ClickHouse. Run ' \
       'BEFORE backfill_user_profiles — that backfill is additive, so running it first writes ' \
       'blank identities no re-run can repair. Full snapshot replace per project (drops ' \
       'merged-away visitors). [PROJECT_ID=..] to limit to one project, else every project. ' \
       'NOTE: this does NOT make sdk_identifier queryable in retention filters — those read ' \
       'session_events, so a freshly imported window also needs SessionBuildJob run with a ' \
       'lookback spanning it (default is 3 days).'
  task sync_visitor_identities: :environment do
    project_ids = ENV['PROJECT_ID'] ? [Integer(ENV['PROJECT_ID'])] : Project.pluck(:id)

    puts "Syncing visitor identities for #{project_ids.size} project(s)..."
    failed = []
    project_ids.each_with_index do |pid, i|
      n = Analytics::VisitorIdentitySyncService.sync_project(pid)
      puts format('  [%<n>d/%<total>d] project=%<pid>d synced=%<c>d',
                  n: i + 1, total: project_ids.size, pid: pid, c: n)
    rescue StandardError => e
      failed << pid
      warn format('  [%<n>d/%<total>d] project=%<pid>d FAILED: %<err>s',
                  n: i + 1, total: project_ids.size, pid: pid, err: "#{e.class}: #{e.message}")
    end
    # Non-zero exit: a partial sync then the additive backfill blanks those tenants forever.
    abort "Done with FAILURES: #{failed.size} project(s) failed: #{failed.join(', ')}" unless failed.empty?
    puts "Done. All #{project_ids.size} project(s) succeeded."
  end

  desc 'Backfill user_profiles (retention cohorts) from events. Bulk-imported tenants ' \
       'have no profiles — only the live batch job writes them. Idempotent; never clobbers ' \
       'live rows. [PROJECT_ID=..] to limit to one project, else every project with events. ' \
       'Shards each project automatically to fit memory; [SHARDS=N] to force a fixed count.'
  task backfill_user_profiles: :environment do
    project_ids =
      if ENV['PROJECT_ID']
        [Integer(ENV['PROJECT_ID'])]
      else
        Analytics::UserProfileBackfillService.project_ids_with_events
      end
    shards = ENV['SHARDS'] ? Integer(ENV['SHARDS']) : :auto

    puts "Backfilling user_profiles for #{project_ids.size} project(s) (shards=#{shards})..."
    failed = []
    project_ids.each_with_index do |pid, i|
      Analytics::UserProfileBackfillService.backfill_project(pid, shards: shards)
      puts format('  [%<n>d/%<total>d] project=%<pid>d ok',
                  n: i + 1, total: project_ids.size, pid: pid)
    rescue StandardError => e
      # One bad tenant (OOM/timeout) must not abort the rest — log and continue
      # so a re-run can target the failures instead of restalling on the same id.
      failed << pid
      warn format('  [%<n>d/%<total>d] project=%<pid>d FAILED: %<err>s',
                  n: i + 1, total: project_ids.size, pid: pid, err: "#{e.class}: #{e.message}")
    end

    # Non-zero exit so automation doesn't read a partial backfill as success.
    abort "Done with FAILURES: #{failed.size} project(s) failed: #{failed.join(', ')}" unless failed.empty?
    puts "Done. All #{project_ids.size} project(s) succeeded."
  end

  desc 'MAU shadow soak (§11c): per instance, current-month PG MAU vs CH rollup vs CH ' \
       'exact. Run during the ramp (≥1 billing cycle) BEFORE flipping CLICKHOUSE_PRIMARY. ' \
       '[INSTANCE_ID=..] to limit to one instance. Exits non-zero on any divergence ' \
       'unless REPORT_ONLY=1.'
  task mau_shadow: :environment do
    abort 'CLICKHOUSE_READ_ENABLED must be true' unless Clickhouse.read_enabled?

    month_start = Date.current.beginning_of_month
    month_end = Date.current
    scope = ENV['INSTANCE_ID'] ? Instance.where(id: Integer(ENV['INSTANCE_ID'])) : Instance.all
    divergent = 0
    rollup_divergent = 0

    puts "instance_id,pg_mau,ch_rollup_mau,ch_exact_mau,delta_exact_vs_pg"
    scope.find_each(batch_size: 500) do |instance|
      next if instance.test.nil? || instance.production.nil?

      project_ids = [instance.test.id, instance.production.id]
      pg = VisitorDailyStatistic
           .where(project_id: project_ids, event_date: month_start..month_end)
           .select(:visitor_id).distinct.count
      ch_rollup = ClickhouseReadService.billing_active_visitors(
        project_ids, start_date: month_start, end_date: month_end
      )
      ch_exact = ClickhouseReadService.billing_active_visitors_exact(
        project_ids, start_date: month_start, end_date: month_end
      )

      delta = ch_exact.nil? ? 'read_failed' : ch_exact - pg
      # Soak passes/fails on exact vs PG (billing's only read); rollup deltas are informational.
      diverged = delta != 0
      divergent += 1 if diverged
      rollup_divergent += 1 if ch_rollup.nil? || ch_rollup != ch_exact
      line = "#{instance.id},#{pg},#{ch_rollup.inspect},#{ch_exact.inspect},#{delta}"
      puts line
      Rails.logger.info("clickhouse.mau.shadow #{line}") if diverged
    end

    puts "Rollup-vs-exact note: #{rollup_divergent} instance(s) differ (informational — billing reads exact only)." if rollup_divergent.positive?
    if divergent.positive?
      # Non-zero exit so cron/automation can't read a divergent soak as green.
      msg = "Shadow pass complete. #{divergent} instance(s) DIVERGENT (exact vs PG)."
      ENV['REPORT_ONLY'] == '1' ? puts(msg) : abort(msg)
    else
      puts "Shadow pass complete. 0 instances divergent (exact vs PG)."
    end
  end
end
