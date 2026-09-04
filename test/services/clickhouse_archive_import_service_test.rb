# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "zlib"
require "csv"

class ClickhouseArchiveImportServiceTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :domains, :links, :redirect_configs

  EC = ClickhouseHistoryBackfillService::EVENT_COLUMNS
  HEADER = %w[id project_id device_id link_id event data created_at updated_at
              engagement_time path ip remote_ip vendor_id platform app_version build processed].freeze

  def idx(col)
    EC.index(col)
  end

  def csv_line(overrides = {})
    h = row_for(overrides)
    CSV.generate_line(HEADER.map { |k| h[k] }).chomp
  end

  def write_gzip(path, data_lines)
    Zlib::GzipWriter.open(path) do |gz|
      gz.puts(HEADER.join(","))
      data_lines.each { |l| gz.puts(l) }
    end
  end

  # import_file with the DB/CH boundaries stubbed: canonical_rows_for is identity, insert captures.
  def with_capture
    captured = []
    ClickhouseHistoryBackfillService.stub(:canonical_rows_for, ->(buf, _sk) { buf }) do
      ClickhouseWriteService.stub(:insert_canonical_events, ->(rows) { captured.concat(rows) }) do
        yield captured
      end
    end
    captured
  end

  def row_for(overrides = {})
    {
      "id" => "42", "project_id" => "637", "device_id" => "557089", "link_id" => "",
      "event" => "app_open", "data" => "", "created_at" => "2025-07-14 14:52:27.734",
      "updated_at" => "2025-07-15 00:00:00", "engagement_time" => "", "path" => "",
      "ip" => "1.2.3.4", "remote_ip" => "1.2.3.4", "vendor_id" => "abc",
      "platform" => "android", "app_version" => "1.18.1", "build" => "199", "processed" => "t"
    }.merge(overrides)
    
  end

  test "map_csv_row casts ids to Integer and aligns to EVENT_COLUMNS" do
    m = ClickhouseArchiveImportService.map_csv_row(row_for)
    assert_equal 42, m[idx(:id)]
    assert_equal 637, m[idx(:project_id)]
    assert_equal 557_089, m[idx(:device_id)]
    assert_instance_of Integer, m[idx(:device_id)]
    assert_equal "app_open", m[idx(:event)]
    assert_equal "android", m[idx(:platform)]
  end

  test "empty link_id maps to nil (truthy '' would mis-join)" do
    assert_nil ClickhouseArchiveImportService.map_csv_row(row_for)[idx(:link_id)]
    assert_equal 99, ClickhouseArchiveImportService.map_csv_row(row_for("link_id" => "99"))[idx(:link_id)]
  end

  test "map_csv_row emits exactly EVENT_COLUMNS.size elements" do
    m = ClickhouseArchiveImportService.map_csv_row(row_for)
    assert_equal ClickhouseHistoryBackfillService::EVENT_COLUMNS.size, m.size,
      "positional contract drift: mapper and EVENT_COLUMNS must stay aligned"
  end

  test "map_csv_row carries data so archived custom events keep properties and ids match PG backfill" do
    json = '{"step":"1","flow":"onboarding"}'
    m = ClickhouseArchiveImportService.map_csv_row(row_for("data" => json))
    assert_equal json, m[idx(:data)], "archive data column must not be discarded"
  end

  test "event_name and session_id are blank (absent in archive)" do
    m = ClickhouseArchiveImportService.map_csv_row(row_for)
    assert_equal "", m[idx(:event_name)]
    assert_equal "", m[idx(:session_id)]
  end

  test "created_at parses to a UTC Time at the correct epoch ms" do
    ca = ClickhouseArchiveImportService.map_csv_row(row_for)[idx(:created_at)]
    assert_respond_to ca, :to_f
    expected_ms = (Time.utc(2025, 7, 14, 14, 52, 27) + 0.734).to_f
    assert_in_delta expected_ms, ca.to_f, 0.001
    # critical: must NOT be String#to_f (which would yield ~2025.0)
    assert_operator ca.to_f, :>, 1_000_000_000
  end

  test "Manifest marks and skips across worker shards" do
    Dir.mktmpdir do |dir|
      m1 = ClickhouseArchiveImportService::Manifest.new(dir)
      m1.mark("/a/x.gz", worker: 0)
      m1.mark("/a/y.gz", worker: 1)
      # fresh instance reads the union of all shards
      m2 = ClickhouseArchiveImportService::Manifest.new(dir)
      assert m2.done?("/a/x.gz")
      assert m2.done?("/a/y.gz")
      assert_not m2.done?("/a/z.gz")
    end
  end

  test "resolve_from_list maps flat manifest entries to local date-folder paths" do
    Dir.mktmpdir do |dir|
      list = File.join(dir, "_manifest.txt")
      File.write(list, <<~TXT)
        events-archive/events-20250915T145644Z-ids-13234104-11229.csv.gz
        events-archive/events-20260102T010101Z-ids-1-2.csv.gz
        _manifest.txt
        not-an-event-file.txt

      TXT
      paths = ClickhouseArchiveImportService.send(:resolve_from_list, list, "/arc")
      assert_equal [
        "/arc/2025-09-15/events-20250915T145644Z-ids-13234104-11229.csv.gz",
        "/arc/2026-01-02/events-20260102T010101Z-ids-1-2.csv.gz"
      ], paths
    end
  end

  test "archive_files reads from file_list when provided (no glob) and honors bounds" do
    Dir.mktmpdir do |dir|
      list = File.join(dir, "list.txt")
      File.write(list, <<~TXT)
        events-archive/events-20250915T010101Z-a.csv.gz
        events-archive/events-20260102T010101Z-b.csv.gz
      TXT
      files = ClickhouseArchiveImportService.archive_files("/arc", from: "2026-01-01", file_list: list)
      assert_equal ["/arc/2026-01-02/events-20260102T010101Z-b.csv.gz"], files
    end
  end

  test "archive_files filters by folder date bounds and sorts" do
    Dir.mktmpdir do |dir|
      %w[2025-09-15 2025-10-01 2026-01-01].each do |d|
        FileUtils.mkdir_p(File.join(dir, d))
        File.write(File.join(dir, d, "events-1.csv.gz"), "")
      end
      files = ClickhouseArchiveImportService.archive_files(dir, from: "2025-10-01", to: "2025-12-31")
      assert_equal 1, files.size
      assert_includes files.first, "2025-10-01"
    end
  end

  test "import_file imports a record whose data field contains a quoted newline (not split/dropped)" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "events-1.csv.gz")
      # A quoted newline inside `data` (JSON often has them) used to split the physical lines and
      # drop the record as malformed. Streaming record parsing now reads it as ONE record.
      multiline = csv_line("id" => "1", "data" => "line1\nline2")
      write_gzip(path, [multiline, csv_line("id" => "2")])
      skipped = Hash.new(0)
      read = inserted = nil
      captured = with_capture do
        read, inserted = ClickhouseArchiveImportService.import_file(path, skipped: skipped)
      end
      assert_equal 2, read, "the multi-line value is ONE record, plus the next row"
      assert_equal 2, inserted, "both records import — a quoted newline no longer splits the row"
      assert_equal 0, skipped[:malformed]
      assert_equal [1, 2], captured.map { |r| r[idx(:id)] }.sort
    end
  end

  test "a corrupt record (unterminated quote) RAISES so the file is not marked done (no silent loss)" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "events-1.csv.gz")
      write_gzip(path, [csv_line("id" => "1"), '9,637,99,,app_open,"unterminated', csv_line("id" => "2")])
      # Streaming CSV can't resume after an unterminated quote (a PG COPY dump is valid CSV, so this
      # is corruption). import_file must RAISE — returning normally would let the caller mark the
      # file complete and silently drop the rest. Raising keeps it retriable and trips the
      # consecutive-failure abort for systemic corruption; canonical is idempotent so re-runs are safe.
      assert_raises(RuntimeError) do
        with_capture { ClickhouseArchiveImportService.import_file(path, skipped: Hash.new(0)) }
      end
    end
  end

  test "import_file lands valid rows in events end-to-end (real CH; dirty rows skipped)" do
    skip_unless_clickhouse!
    ch_orig = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true
    truncate_clickhouse_tables
    pid = projects(:one).id
    did = devices(:ios_device).id
    Dir.mktmpdir do |dir|
      path = File.join(dir, "events-1.csv.gz")
      write_gzip(path, [
                   csv_line("id" => "1001", "project_id" => pid.to_s, "device_id" => did.to_s,
                            "created_at" => "2025-07-14 14:52:27.734"),
                   csv_line("id" => "1002", "project_id" => pid.to_s, "device_id" => did.to_s,
                            "created_at" => "2025-07-14 14:52:28.000"),
                   # wrong field count (extra unquoted field) → skip-and-continue (parser state stays intact)
                   "#{csv_line('project_id' => pid.to_s, 'device_id' => did.to_s)},EXTRA"
                 ])
      skipped = Hash.new(0)
      read, inserted = ClickhouseArchiveImportService.import_file(path, skipped: skipped)
      assert_equal 3, read
      assert_equal 2, inserted, "only the two clean rows insert; the extra-field row is skipped"
      assert_operator skipped[:malformed], :>=, 1

      count = Clickhouse.with do |c|
        c.select_value("SELECT count() FROM events FINAL WHERE project_id = #{Integer(pid)}")
      end
      assert_equal 2, count, "the two clean rows land in canonical; dirty rows did not"
    end
  ensure
    Rails.application.config.clickhouse_write_enabled = ch_orig unless ch_orig.nil?
  end

  test "import_file excludes events after the cutover (max_created_at) — precise per-event bound" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "events-1.csv.gz")
      write_gzip(path, [
                   csv_line("id" => "1", "created_at" => "2025-09-19 10:00:00.000"),
                   csv_line("id" => "2", "created_at" => "2025-09-21 10:00:00.000") # after cutover
                 ])
      skipped = Hash.new(0)
      inserted = nil
      with_capture do
        _read, inserted = ClickhouseArchiveImportService.import_file(
          path, skipped: skipped, max_created_at: Time.find_zone!("UTC").parse("2025-09-20").end_of_day
        )
      end
      assert_equal 1, inserted, "event after the cutover day must be excluded"
      assert_equal 1, skipped[:after_cutover]
    end
  end

  test "import_file raises on a missing required header (schema drift), even without a project filter" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "events-1.csv.gz")
      Zlib::GzipWriter.open(path) do |gz|
        gz.puts((HEADER - ["created_at"]).join(",")) # drop a required column
        gz.puts(csv_line)
      end
      assert_raises(RuntimeError) do
        with_capture { ClickhouseArchiveImportService.import_file(path, skipped: Hash.new(0)) }
      end
    end
  end

  test "import_file rejects a row with the wrong field count (unquoted comma shifts columns)" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "events-1.csv.gz")
      # unquoted comma (e.g. inside the data field) → parses fine but yields one extra field
      bad = "#{csv_line},extra"
      write_gzip(path, [csv_line("id" => "1"), bad, csv_line("id" => "2")])
      skipped = Hash.new(0)
      read = inserted = nil
      with_capture do
        read, inserted = ClickhouseArchiveImportService.import_file(path, skipped: skipped)
      end
      assert_equal 3, read
      assert_equal 2, inserted, "the column-shifted row must not be mapped/inserted"
      assert_operator skipped[:malformed], :>=, 1
    end
  end

  test "import_file filters rows by project_ids" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "events-1.csv.gz")
      write_gzip(path, [csv_line("project_id" => "637"), csv_line("project_id" => "999")])
      captured = with_capture do
        _read, inserted = ClickhouseArchiveImportService.import_file(path, skipped: Hash.new(0), project_ids: Set[637])
        assert_equal 1, inserted
      end
      assert_equal [637], captured.map { |r| r[idx(:project_id)] }.uniq
    end
  end

  test "import_file filters by project_ids regardless of column order (name-based, not positional)" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "events-1.csv.gz")
      # project_id no longer column 2 — streaming maps by header NAME, so the filter still works
      # (the old positional cheap_project_id guard is gone).
      rotated = HEADER.rotate(1)
      Zlib::GzipWriter.open(path) do |gz|
        gz.puts(rotated.join(","))
        gz.puts(CSV.generate_line(rotated.map { |k| row_for("project_id" => "637")[k] }).chomp)
        gz.puts(CSV.generate_line(rotated.map { |k| row_for("project_id" => "999")[k] }).chomp)
      end
      captured = with_capture do
        _read, inserted = ClickhouseArchiveImportService.import_file(path, skipped: Hash.new(0), project_ids: Set[637])
        assert_equal 1, inserted
      end
      assert_equal [637], captured.map { |r| r[idx(:project_id)] }.uniq
    end
  end

  test "import_file counts out-of-range timestamps as skipped and does not insert them" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "events-1.csv.gz")
      write_gzip(path, [csv_line("created_at" => "1929-01-01 00:00:00"), csv_line("id" => "2")])
      skipped = Hash.new(0)
      with_capture do
        _read, inserted = ClickhouseArchiveImportService.import_file(path, skipped: skipped)
        assert_equal 1, inserted
      end
      assert_equal 1, skipped[:bad_timestamp]
    end
  end
end
