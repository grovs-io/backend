# frozen_string_literal: true

require "zlib"
require "csv"
require "set"
require "fileutils"

# Imports the cold-storage event archive (gzipped CSV dumps of the PG `events` table)
# into ClickHouse `events`, reusing the EXACT enrichment of the PG history
# backfill (ClickhouseHistoryBackfillService.canonical_rows_for). Events are NOT written
# to Postgres — only the dimension tables (devices/visitors/links) are read for joins.
#
# Idempotent: canonical is a ReplacingMergeTree keyed on the frozen event_id, so
# re-processing a file never inflates counts — EXCEPT across the 2026-07-13 identity
# amendment (see ClickhouseHistoryBackfillService header); the same overlay guard runs
# at import start. A per-file Manifest lets a parallel run resume after interruption
# by skipping already-completed files.
#
# See docs/plans/2026-06-29-archive-to-clickhouse-full-import-design.md
module ClickhouseArchiveImportService
  BATCH_SIZE = Integer(ENV.fetch("ARCHIVE_IMPORT_BATCH_SIZE", 20_000))

  # The source events carry some clock-skewed garbage timestamps (e.g. 1929, 1970)
  # from devices with broken clocks. Legacy PG metrics never counted them (the oracle
  # starts 2024-03-07), and far-past dates would explode the canonical partition span
  # and the rollup-rebuild range. Skip anything outside [MIN_CREATED_AT, now + 1 day]
  # and count it as skipped[:bad_timestamp]. Floor is well below any parity window.
  MIN_CREATED_AT = Time.find_zone!("UTC").parse(ENV.fetch("ARCHIVE_IMPORT_MIN_DATE", "2020-01-01"))

  Result = Struct.new(:files, :failed_files, :events_read, :rows_inserted, :skipped, keyword_init: true)

  # Consecutive per-file failures that signal a systemic problem (bad header, schema/auth,
  # missing constant) rather than scattered dirty files — abort instead of churning the shard.
  FILE_FAILURE_THRESHOLD = Integer(ENV.fetch("ARCHIVE_IMPORT_FILE_FAILURE_THRESHOLD", 5))

  # Every column map_csv_row reads. A full run (project_ids nil) skips the positional header
  # check, so without this a renamed/dropped column maps silently to "" for every row.
  REQUIRED_HEADERS = %w[id project_id device_id event link_id platform app_version build
                        vendor_id engagement_time ip remote_ip path created_at data].freeze

  # Position of created_at in the EVENT_COLUMNS-ordered array map_csv_row emits — derived, not
  # hard-coded, so a column reorder can't silently make safe_map validate the wrong field.
  CREATED_AT_IDX = ClickhouseHistoryBackfillService::EVENT_COLUMNS.index(:created_at)

  # Tracks completed files in append-only, per-worker shards so forked workers never
  # contend on a single file. On resume, the union of all shards is skipped.
  class Manifest
    def initialize(dir)
      @dir = dir
      FileUtils.mkdir_p(@dir)
    end

    def completed
      @completed ||= Dir.glob(File.join(@dir, "manifest.worker-*"))
                        .flat_map { |f| File.readlines(f, chomp: true) }
                        .to_set
    end

    def done?(path)
      completed.include?(path)
    end

    # Append a single line (atomic on POSIX) and flush so a crash mid-run keeps the
    # record. Reopen per call to stay fork-safe.
    def mark(path, worker:)
      File.open(File.join(@dir, "manifest.worker-#{worker}"), "a") do |f|
        f.puts(path)
        f.flush
      end
    end
  end

  # Whole-store variant of the backfill guard: archive imports target a fresh or
  # rebuilt store, so ANY pre-existing property-bearing custom row means overlay risk.
  def self.assert_no_property_event_overlay!(project_ids)
    return if ENV["ALLOW_PROPERTY_EVENT_OVERLAY"] == "1"

    scope = project_ids ? "project_id IN (#{project_ids.map { |id| Integer(id) }.join(', ')}) AND " : ""
    existing = Clickhouse.with do |conn|
      conn.select_value(
        "SELECT count() FROM events WHERE #{scope}" \
        "event_type IN ('#{Grovs::Events::CUSTOM}', '#{Grovs::Events::SCREEN_VIEW}') " \
        "AND toString(properties) != '{}'"
      )
    end
    return if existing.to_i.zero?

    raise "events already holds #{existing} property-bearing custom/screen_view row(s); " \
          "importing over them rekeys pre-amendment ids and double-counts. Truncate + rebuild, " \
          "or set ALLOW_PROPERTY_EVENT_OVERLAY=1 to proceed knowingly."
  end
  private_class_method :assert_no_property_event_overlay!

  # Map one archive CSV row (header-keyed) to an EVENT_COLUMNS-ordered array.
  # Casts ids to Integer (build_rows uses them as integer hash keys — a String id would
  # make every row look like a missing device). created_at is parsed to a UTC Time so
  # generate_event_id's `created_at.to_f * 1000` produces the same ms as the PG backfill.
  # event_name/session_id are absent in the archive → "".
  def self.map_csv_row(row)
    link = row["link_id"]
    [
      Integer(row["id"]),
      Integer(row["project_id"]),
      Integer(row["device_id"]),
      row["event"].to_s,
      "",                                   # event_name (not in archive)
      "",                                   # session_id (not in archive)
      (link.nil? || link.to_s.empty? ? nil : Integer(link)),
      row["platform"].to_s,
      row["app_version"].to_s,
      row["build"].to_s,
      row["vendor_id"].to_s,
      row["engagement_time"],               # build_canonical_row applies .to_i
      row["ip"].to_s,
      row["remote_ip"].to_s,
      row["path"].to_s,
      parse_time(row["created_at"]),
      row["data"]
    ]
  end

  def self.parse_time(str)
    return nil if str.nil? || str.to_s.empty?

    # Archive timestamps are naive UTC (PG stored UTC, dump is UTC).
    Time.find_zone!("UTC").parse(str.to_s)
  end
  private_class_method :parse_time

  # Stream one gzip file, batch rows, enrich, insert. Returns [events_read, rows_inserted].
  # Malformed-but-parseable rows (bad id, unparseable time, wrong field count) are counted in
  # skipped[:malformed] and skipped; an UNPARSEABLE record (corrupt CSV) raises so the file is
  # not marked done. project_ids (Set/Array of Integer) optionally restricts to those projects,
  # matched by the parsed project_id column so a single-project run skips other tenants' work.
  # Scrubs invalid UTF-8 as CSV streams, so a corrupt byte degrades one field instead of
  # aborting the parse. Wrapping gets/read keeps CSV's multi-line record handling intact —
  # the per-read scrub never changes record boundaries.
  class ScrubbingReader
    delegate :eof?, to: :@io

    def initialize(io) = @io = io
    def gets(*args) = (s = @io.gets(*args)) && s.force_encoding(Encoding::UTF_8).scrub
    def read(*args) = (s = @io.read(*args)) && s.force_encoding(Encoding::UTF_8).scrub
  end

  def self.import_file(path, batch_size: BATCH_SIZE, skipped: Hash.new(0), project_ids: nil, max_created_at: nil)
    events_read = 0
    rows_inserted = 0
    buffer = []

    Zlib::GzipReader.open(path) do |gz|
      # Streaming record parser: handles quoted newlines in the `data`/`path` columns correctly
      # (the old line-based reader split such records and dropped them as malformed). headers:
      # true maps by column name, so we no longer depend on positional column order.
      csv = CSV.new(ScrubbingReader.new(gz), headers: true, return_headers: false)
      headers_checked = false

      loop do
        row = begin
          csv.shift
        rescue CSV::MalformedCSVError, ArgumentError => e
          # The streaming parser can't resume after a malformed record. Returning normally would
          # let the CALLER mark the file COMPLETE — silently discarding the rest and skipping it on
          # resume — and a malformed header/first row would bypass the schema-drift guard below.
          # RAISE instead: the file stays UNMARKED (retriable), a systematically corrupt file trips
          # the consecutive-failure abort, and canonical is idempotent so re-processing is safe.
          raise "archive record parse failed in #{File.basename(path)} after #{events_read} " \
                "rows read: #{e.class}: #{e.message}"
        end
        break if row.nil?

        unless headers_checked
          missing = REQUIRED_HEADERS - (csv.headers || [])
          raise "archive header missing columns #{missing.inspect} (schema drift?)" if missing.any?
          headers_checked = true
        end

        # Count AFTER the project filter so events_read = rows actually processed. Otherwise a
        # project-filtered calibrate run counts fast-rejected foreign rows and reports an inflated
        # rows/sec → optimistic ETA. For a full run (no filter) every row is counted, unchanged.
        next if project_ids && !project_ids.include?(row["project_id"].to_i)
        events_read += 1

        # A genuinely malformed row (e.g. an unquoted delimiter) parses to the wrong field
        # count and would mis-map id/created_at/etc — skip it. A quoted newline now parses to
        # the CORRECT count, so it is no longer caught here (that is the fix).
        if row.fields.length != (csv.headers || []).length
          skipped[:malformed] += 1
          next
        end

        # safe_map already rescues map_csv_row's Integer()/parse errors internally → nil.
        mapped = safe_map(row.to_h, skipped, max_created_at)
        next if mapped.nil?

        buffer << mapped
        if buffer.size >= batch_size
          rows_inserted += flush(buffer, skipped)
          buffer = []
        end
      end
    end
    rows_inserted += flush(buffer, skipped) if buffer.any?

    [events_read, rows_inserted]
  end

  def self.safe_map(row, skipped, max_created_at = nil)
    mapped = map_csv_row(row)
    ca = mapped[CREATED_AT_IDX]
    if ca.nil?               # created_at failed to parse
      skipped[:malformed] += 1
      return nil
    end
    if ca < MIN_CREATED_AT || ca > (Time.now.utc + 86_400)
      skipped[:bad_timestamp] += 1
      return nil
    end
    # Per-EVENT cutover bound (precise, unlike the folder-date TO): keeps the content-hash
    # archive keyspace disjoint from the live UUID window so the parity gate doesn't drift.
    if max_created_at && ca > max_created_at
      skipped[:after_cutover] += 1
      return nil
    end
    mapped
  rescue ArgumentError, TypeError
    skipped[:malformed] += 1
    nil
  end
  private_class_method :safe_map

  def self.flush(buffer, skipped)
    ch_rows = ClickhouseHistoryBackfillService.canonical_rows_for(buffer, skipped)
    return 0 if ch_rows.empty?

    # insert_canonical_events returns false on CH failure — must NOT be reported as inserted,
    # or the file gets marked done and is permanently skipped on resume (silent data loss).
    unless ClickhouseWriteService.insert_canonical_events(ch_rows)
      raise "events insert failed for #{ch_rows.size} rows (see ClickhouseWriteService logs)"
    end

    ch_rows.size
  end
  private_class_method :flush

  # The full ordered list of archive files. Prefer a precomputed file_list (the archive's
  # _manifest.txt — avoids globbing 1.3M files over the volume every run); otherwise glob.
  # from/to bound the date-named folders (inclusive, e.g. "2025-09-15"). Returns absolute
  # local paths, sorted for deterministic sharding/resume.
  def self.archive_files(archive_dir, from: nil, to: nil, file_list: nil)
    paths =
      if file_list
        resolve_from_list(file_list, archive_dir)
      else
        Dir.glob(File.join(archive_dir, "*", "*.csv.gz"))
      end
    paths.select do |path|
      folder = File.basename(File.dirname(path))
      (from.nil? || folder >= from) && (to.nil? || folder <= to)
    end.sort
  end

  # Read a manifest of relative keys (e.g. "events-archive/events-20250915T..-ids-..csv.gz")
  # and resolve each to its local path. The date folder is derived from the YYYYMMDD in the
  # filename (local layout is archive_dir/<YYYY-MM-DD>/<basename>). Non-event lines skipped.
  def self.resolve_from_list(file_list, archive_dir)
    dropped = 0
    resolved = File.readlines(file_list, chomp: true).filter_map do |line|
      base = File.basename(line.strip)
      next if base.empty?

      m = base.match(/\Aevents-(\d{4})(\d{2})(\d{2})T.*\.csv\.gz\z/)
      if m.nil?
        # Surface silently-excluded entries (renamed/re-compressed files) — otherwise the run
        # reports clean completion while skipping history, defeating the parity gate's premise.
        dropped += 1
        next
      end

      File.join(archive_dir, "#{m[1]}-#{m[2]}-#{m[3]}", base)
    end
    if dropped.positive?
      Rails.logger.warn("ClickhouseArchiveImportService: resolve_from_list dropped #{dropped} " \
                        "file-list entries not matching events-YYYYMMDDT*.csv.gz")
    end
    resolved
  end
  private_class_method :resolve_from_list

  # Import this worker's shard, single process. Parallelism is achieved by launching N
  # processes with distinct (worker_index, worker_count) — no fork, no shared sockets, so
  # it is robust on macOS/servers. Each worker takes files where index % count == self,
  # skips manifest-done files, and appends to its own manifest shard.
  def self.import(archive_dir:, manifest_dir:, batch_size: BATCH_SIZE, from: nil, to: nil,
                  project_ids: nil, file_list: nil, worker_index: 0, worker_count: 1,
                  logger: Rails.logger)
    raise "ClickHouse writes are disabled (set CLICKHOUSE_WRITE_ENABLED=true)" unless Clickhouse.enabled?

    project_ids = nil if project_ids.respond_to?(:empty?) && project_ids.empty? # blank PROJECT_IDS must not skip everything
    assert_no_property_event_overlay!(project_ids)
    # Precise per-event upper bound from TO (folder-date filtering alone can't align to the cutover).
    max_created_at = to && Time.find_zone!("UTC").parse(to).end_of_day
    manifest = Manifest.new(manifest_dir)
    all_files = archive_files(archive_dir, from: from, to: to, file_list: file_list)
    mine = all_files.each_with_index.select { |_, i| i % worker_count == worker_index }.map(&:first)
    pending = mine.reject { |f| manifest.done?(f) }
    logger.info("ClickhouseArchiveImportService[w#{worker_index}/#{worker_count}]: " \
                "#{all_files.size} total, #{mine.size} mine, #{pending.size} pending" \
                "#{project_ids ? ", projects=#{project_ids.to_a.inspect}" : ''}")
    return Result.new(files: 0, failed_files: 0, events_read: 0, rows_inserted: 0, skipped: {}) if pending.empty?

    skipped = Hash.new(0)
    read = 0
    inserted = 0
    processed = 0
    consecutive_failures = 0
    pending.each_with_index do |path, n|
      begin
        r, i = import_file(path, batch_size: batch_size, skipped: skipped,
                           project_ids: project_ids, max_created_at: max_created_at)
      rescue Errno::ENOENT => e
        # Missing file (e.g. not-yet-rsynced shard) — environmental, not "systemic"; don't trip the abort.
        skipped[:missing_files] += 1
        logger.error("[w#{worker_index}] MISSING #{File.basename(path)}: #{e.message} — skipped (download incomplete?)")
        next
      rescue StandardError => e
        # A corrupt/truncated gzip must not kill the worker and strand the rest of the shard.
        # Leave the file UNMARKED so it's visible and retriable, not silently lost.
        skipped[:failed_files] += 1
        consecutive_failures += 1
        logger.error("[w#{worker_index}] FAILED #{File.basename(path)}: #{e.class}: #{e.message} — skipped, not marked done")
        logger.debug { "[w#{worker_index}] #{path}\n#{e.backtrace&.join("\n")}" }
        # Many failures in a row mean a systemic error (header/schema/auth/missing constant),
        # not dirty data — abort loudly rather than churn the whole shard into the failed bucket.
        if consecutive_failures >= FILE_FAILURE_THRESHOLD
          raise "Aborting after #{consecutive_failures} consecutive file failures (likely systemic, not dirty data). " \
                "Last: #{e.class}: #{e.message}"
        end
        next
      end
      consecutive_failures = 0
      processed += 1
      read += r
      inserted += i
      manifest.mark(path, worker: worker_index)
      logger.info("[w#{worker_index}] (#{n + 1}/#{pending.size}) #{File.basename(path)} read=#{r} inserted=#{i}") if (n % 50).zero?
    end

    Result.new(files: processed, failed_files: skipped[:failed_files], events_read: read, rows_inserted: inserted, skipped: skipped)
  end

  # Process the first N files single-process and report throughput so the operator can
  # pick worker count / get an ETA before committing to the full run. Does not advance the
  # manifest (calibration is throwaway; canonical dedups the re-insert).
  def self.calibrate(archive_dir:, batch_size: BATCH_SIZE, from: nil, to: nil,
                     file_list: nil, project_ids: nil, sample: 20, logger: Rails.logger)
    # Without writes, insert_canonical_events no-ops but flush still returns ch_rows.size, so rows
    # look "inserted" while the dominant CH-insert cost is excluded — the measured rate (and the
    # worker-count ETA derived from it) would be wildly optimistic. Require writes for a real number.
    unless Clickhouse.enabled?
      raise "ClickHouse writes are disabled — calibrate would measure a rate excluding the insert " \
            "cost (set CLICKHOUSE_WRITE_ENABLED=true)"
    end

    project_ids = nil if project_ids.respond_to?(:empty?) && project_ids.empty?
    max_created_at = to && Time.find_zone!("UTC").parse(to).end_of_day
    files = archive_files(archive_dir, from: from, to: to, file_list: file_list).first(sample)
    raise "no files to calibrate" if files.empty?

    skipped = Hash.new(0)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    read = 0
    files.each do |f|
      r, = import_file(f, batch_size: batch_size, skipped: skipped,
                       project_ids: project_ids, max_created_at: max_created_at)
      read += r
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    rate = elapsed.positive? ? (read / elapsed) : 0
    logger.info(format("Calibration: %<files>d files, %<rows>d rows in %<secs>.1fs = %<rate>d rows/sec (single stream)",
                       files: files.size, rows: read, secs: elapsed, rate: rate))
    { files: files.size, events_read: read, seconds: elapsed, rows_per_sec: rate, skipped: skipped }
  end
end
