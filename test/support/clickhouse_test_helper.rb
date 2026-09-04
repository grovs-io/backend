# frozen_string_literal: true

require_relative '../../lib/clickhouse/migration'
require_relative '../../lib/clickhouse/schema_migration'
require_relative '../../lib/clickhouse/migrator'

module ClickhouseTestHelper
  TEST_CLICKHOUSE_VARIABLES = { mutations_sync: 1, async_insert: 0, wait_for_async_insert: 1 }.freeze

  def self.included(base)
    base.setup do
      @__clickhouse_test_started = false
      # Pin at setup, not just teardown: an unpinned test method runs in the previous class's database.
      if ClickhouseTestHelper.available?
        use_isolated_clickhouse_database!
        ClickhouseTestHelper.ensure_tables_cached!
      end
    end

    base.teardown do
      truncate_clickhouse_tables if @__clickhouse_test_started && ClickhouseTestHelper.available?
    end
  end

  # Pings the ClickHouse server directly (database-agnostic /ping endpoint).
  # Result is cached for the process lifetime — CH won't appear mid-test-run.
  def self.available?
    return @available if defined?(@available)

    @available = begin
      uri = URI.parse(ENV.fetch('CLICKHOUSE_URL', 'http://localhost:8123'))
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 2) do |http|
        http.get('/ping')
      end
      response.is_a?(Net::HTTPSuccess)
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Net::OpenTimeout, Net::ReadTimeout, SocketError
      false
    end
  end

  # Creates tables via the migration framework. Idempotent, cached per process.
  # Called by parallelize_setup (eager) or truncate_clickhouse_tables (lazy).
  # Setup-path variant: trusts the memo instead of re-verifying, so pinning costs no round trip.
  def self.ensure_tables_cached!
    @tables_created_by_database ||= {}
    return if @tables_created_by_database[Clickhouse.default_database]

    ensure_tables!
  end

  def self.ensure_tables!
    database = Clickhouse.default_database
    @tables_created_by_database ||= {}
    return if @tables_created_by_database[database] && required_tables_present?

    run_migrations!
    reset_schema! unless required_tables_present?
    @tables_created_by_database[database] = true
  end

  MATERIALIZED_VIEWS = %w[
    mv_project_country_daily mv_purchase_product_daily
    mv_purchase_project_daily mv_visitor_daily mv_link_daily
    mv_project_daily mv_screen_daily mv_billing_active_visitors_daily
    mv_project_version_daily mv_project_source_daily mv_project_property_daily
  ].freeze

  LEGACY_PHYSICAL_TABLES = %w[screen_daily].freeze

  def self.reset_schema!
    database = Clickhouse.default_database
    @tables_created_by_database ||= {}
    @tables_created_by_database[database] = false

    Clickhouse.with do |conn|
      (MATERIALIZED_VIEWS + PHYSICAL_TABLES.reverse + LEGACY_PHYSICAL_TABLES).each do |table|
        conn.execute("DROP TABLE IF EXISTS `#{table}`")
      end
      conn.execute("DROP TABLE IF EXISTS `schema_migrations`")
    end

    run_migrations!
    @tables_created_by_database[database] = true
  end

  # Created once per process, not per call: reset_schema! drops tables, never the database,
  # so nothing in a test run can invalidate the set. Each CREATE is one ephemeral port.
  def self.use_database!(database)
    @created_databases ||= Set.new
    unless @created_databases.include?(database)
      Clickhouse.build_connection(database: 'default')
                .execute("CREATE DATABASE IF NOT EXISTS `#{database}`")
      @created_databases << database
    end
    return if Clickhouse.default_database == database

    raw_url = ENV.fetch('CLICKHOUSE_URL', 'http://localhost:8123')
    uri = URI.parse(raw_url)
    ClickHouse::Client.configuration.databases.delete(:main)
    ClickHouse::Client.configuration.register_database(:main,
      database: database,
      url: "#{uri.scheme}://#{uri.host}:#{uri.port || 8123}",
      username: uri.user || 'default',
      password: uri.password || '',
      variables: TEST_CLICKHOUSE_VARIABLES
    )
    Clickhouse.reset_connection!
  end

  def self.remember_base_database!
    @base_database ||= Clickhouse.default_database
  end

  def self.base_database
    remember_base_database!
  end

  def self.sanitize_database_part(value)
    value.to_s.gsub(/[^a-zA-Z0-9_]/, "_").downcase
  end

  def self.required_tables_present?
    required = PHYSICAL_TABLES + ["schema_migrations"]
    (required - existing_tables).empty? && billing_active_visitors_daily_current?
  rescue ClickHouse::Client::DatabaseError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
         Net::OpenTimeout, Net::ReadTimeout, SocketError
    false
  end

  def self.billing_active_visitors_daily_current?
    Clickhouse.with do |conn|
      table = conn.select_one(
        "SELECT engine FROM system.tables WHERE database = currentDatabase() " \
        "AND name = 'billing_active_visitors_daily'"
      )
      column = conn.select_one(
        "SELECT type FROM system.columns WHERE database = currentDatabase() " \
        "AND table = 'billing_active_visitors_daily' AND name = 'visitors_state'"
      )

      table&.fetch("engine") == "AggregatingMergeTree" &&
        column&.fetch("type") == "AggregateFunction(uniqExact, UInt64)"
    end
  end

  def self.existing_tables
    Clickhouse.with do |conn|
      conn.select_all("SELECT name FROM system.tables WHERE database = currentDatabase()").map { |row| row["name"] }
    end
  end

  def self.run_migrations!
    Clickhouse::Migrator.new.migrate
  rescue Clickhouse::Migrator::MigrationLockError
    raise unless Rails.env.test?

    REDIS.with { |conn| conn.del(Clickhouse::Migrator::LOCK_KEY) }
    Clickhouse::Migrator.new.migrate
  end

  def with_clickhouse_primary
    prev = Rails.application.config.clickhouse_primary
    Rails.application.config.clickhouse_primary = true
    yield
  ensure
    Rails.application.config.clickhouse_primary = prev
  end

  # Call at the top of any test that needs ClickHouse.
  # Skips gracefully if CH isn't running — existing tests unaffected.
  def skip_unless_clickhouse!
    if ClickhouseTestHelper.available?
      @__clickhouse_test_started = true
      truncate_clickhouse_tables
      return
    end

    if ActiveModel::Type::Boolean.new.cast(ENV.fetch("CLICKHOUSE_REQUIRED", false))
      flunk "ClickHouse is required for this test run but is not available"
    end

    skip 'ClickHouse not available'
  end

  # Physical tables safe to truncate/query (excludes MVs and schema_migrations).
  PHYSICAL_TABLES = %w[
    events purchase_events user_profiles
    project_daily link_daily visitor_daily
    purchase_project_daily purchase_product_daily project_country_daily
    session_events session_summary billing_active_visitors_daily
    project_version_daily project_source_daily project_property_daily
    project_metrics_daily link_metrics_daily visitor_metrics_daily link_session_daily
    visitor_identity_map visitor_identities
    visitor_acquisition visitor_last_touch_daily visitor_dimension_daily
    visitor_first_seen_daily link_dimensions
  ].freeze

  # Truncate all ClickHouse tables. Call in test setup for a clean slate.
  # Ensures tables exist first (handles non-parallel runs where
  # parallelize_setup doesn't fire). Skips materialized views.
  def stub_ch_flags(value)
    @original_ch_write = Rails.application.config.clickhouse_write_enabled
    @original_ch_read = Rails.application.config.clickhouse_read_enabled
    Rails.application.config.clickhouse_write_enabled = value
    Rails.application.config.clickhouse_read_enabled = value
  end

  def unstub_ch_flags
    return unless defined?(@original_ch_write)

    Rails.application.config.clickhouse_write_enabled = @original_ch_write
    Rails.application.config.clickhouse_read_enabled = @original_ch_read
  end

  def truncate_clickhouse_tables
    use_isolated_clickhouse_database!
    ClickhouseTestHelper.ensure_tables!
    Clickhouse.with do |conn|
      PHYSICAL_TABLES.each do |table|
        conn.execute("TRUNCATE TABLE IF EXISTS `#{table}`")
      end
    end
  end

  def use_isolated_clickhouse_database!
    return unless Rails.env.test?

    ClickhouseTestHelper.remember_base_database!
    database = [
      ClickhouseTestHelper.base_database,
      ClickhouseTestHelper.sanitize_database_part(self.class.name.underscore)
    ].join("_")

    ClickhouseTestHelper.use_database!(database)
  end

  # Query a CH table for a project. Returns array of hashes.
  # table and project_id are validated; extra_where is raw SQL (test-only, never user input).
  def ch_query(table, project_id, extra_where: nil)
    raise ArgumentError, "Unknown CH table: #{table}" unless PHYSICAL_TABLES.include?(table)

    sql = +"SELECT * FROM `#{table}` WHERE project_id = #{Integer(project_id)}"
    sql << " AND #{extra_where}" if extra_where
    Clickhouse.with { |conn| conn.select_all(sql) }
  end

  REQUIRED_EVENT_KEYS = %i[project_id event_type created_at].freeze

  # Insert one or more event rows (hashes) into the single deduped `events` table.
  # Each row gets a non-blank event_id (dedup key) + ingested_at (version) via
  # canonical_fixture_row, mirroring the production write guard. Each seed call is
  # a DISTINCT event (unique event_id when none given); tests exercising dedup pass
  # an explicit duplicate event_id to force the ReplacingMergeTree/FINAL collapse.
  def insert_ch_events(rows)
    rows = [rows] if rows.is_a?(Hash)
    rows.each do |row|
      missing = REQUIRED_EVENT_KEYS.reject { |k| row.key?(k) || row.key?(k.to_s) }
      raise ArgumentError, "Missing required event fields: #{missing.join(', ')}" if missing.any?
    end
    prepared = rows.map { |row| canonical_fixture_row(row) }
    Clickhouse.with { |conn| conn.insert('events', prepared) }
    rebuild_breakdown_rollups_for(prepared) if @ch_auto_rebuild_breakdowns
  end

  # The breakdown rollups (project_daily/link_daily/visitor_daily/country/version/
  # source/property/billing) are no longer MV-fed; they are rebuilt from canonical.
  # Tests that seed events then read those rollups (and previously relied on MV
  # auto-population) set `@ch_auto_rebuild_breakdowns = true` in setup — this then
  # rebuilds the affected partitions after each seed, so the rollups are fresh at
  # read time. Rebuild is whole-partition (project-agnostic), so we dedup by
  # partition.
  BREAKDOWN_ROLLUP_KEYS = %i[
    project_breakdown link_breakdown visitor_breakdown country version source property billing first_seen
  ].freeze

  def rebuild_breakdown_rollups_for(rows)
    partitions = rows.map { |r| ch_partition_of(r[:created_at]) }.compact.uniq
    partitions.each do |p|
      ClickhouseRollupRebuildService.rebuild_partition_range(p, p, rollups: BREAKDOWN_ROLLUP_KEYS)
    end
  end

  def ch_partition_of(created_at)
    t = created_at.is_a?(String) ? Time.zone.parse(created_at) : created_at
    t&.strftime('%Y%m')
  end

  # Rebuild the breakdown rollups for every partition currently in canonical.
  # For pipeline-based tests (real BatchEventProcessorJob ingestion) that read the
  # breakdown rollups: the pipeline writes canonical but rollup rebuild is a
  # separate scheduled job, so call this after ingesting.
  def rebuild_ch_breakdowns!
    rows = Clickhouse.with do |conn|
      conn.select_all("SELECT DISTINCT toYYYYMM(toDate(created_at)) AS p FROM events")
    end
    rows.map { |r| r["p"].to_s }.each do |p|
      ClickhouseRollupRebuildService.rebuild_partition_range(p, p, rollups: BREAKDOWN_ROLLUP_KEYS)
    end
  end

  # Builds the events mirror of a fixture event row. Each seeded row is
  # a DISTINCT event: when the caller gives no event_id we assign a unique one, so
  # N seed calls model N distinct events (as the plain events table keeps them),
  # not N collisions. Tests exercising dedup pass an EXPLICIT duplicate event_id
  # (or re-insert the same row) to force the ReplacingMergeTree/FINAL collapse.
  # ingested_at is stamped from created_at (a CH-compatible representation the
  # client already accepts for events rows).
  def canonical_fixture_row(row)
    r = row.transform_keys(&:to_sym)
    r[:event_id] = "seed-#{SecureRandom.hex(12)}" if r[:event_id].to_s.empty?
    r[:ingested_at] ||= r[:created_at]
    r
  end

  # Count events (deduped — FINAL collapses replays/re-ingests by event_id) in the
  # single events store, optionally filtered by event_type.
  def ch_event_count(project_id, event_type: nil)
    sql = +"SELECT COUNT(*) FROM events FINAL WHERE project_id = #{Integer(project_id)}"
    if event_type
      escaped = event_type.to_s.gsub("'", "''")
      sql << " AND event_type = '#{escaped}'"
    end
    Clickhouse.with { |conn| conn.select_value(sql) }
  end

  # Select events from the plain events table for a project. Returns array of
  # hashes. columns must be '*' or an array of valid identifier names.
  def ch_select_events(project_id, columns: '*')
    cols = if columns == '*'
             '*'
           else
             Array(columns).each do |c|
               raise ArgumentError, "Invalid column name: #{c}" unless c.to_s.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/)
             end.join(', ')
           end
    Clickhouse.with do |conn|
      conn.select_all("SELECT #{cols} FROM events FINAL WHERE project_id = #{Integer(project_id)} ORDER BY created_at")
    end
  end

  REQUIRED_SESSION_EVENT_KEYS = %i[project_id session_id visitor_id event_type created_at].freeze

  # Insert rows into session_events table.
  def insert_ch_session_events(rows)
    rows = [rows] if rows.is_a?(Hash)
    rows.each do |row|
      missing = REQUIRED_SESSION_EVENT_KEYS.reject { |k| row.key?(k) || row.key?(k.to_s) }
      raise ArgumentError, "Missing required session_event fields: #{missing.join(', ')}" if missing.any?
      row[:event_date] ||= row[:created_at].to_date.to_s if row[:created_at]
    end
    Clickhouse.with { |conn| conn.insert('session_events', rows) }
  end

  REQUIRED_USER_PROFILE_KEYS = %i[project_id visitor_id first_seen last_seen].freeze

  # Insert rows into user_profiles table.
  def insert_ch_user_profiles(rows)
    rows = [rows] if rows.is_a?(Hash)
    rows.each do |row|
      missing = REQUIRED_USER_PROFILE_KEYS.reject { |k| row.key?(k) || row.key?(k.to_s) }
      raise ArgumentError, "Missing required user_profile fields: #{missing.join(', ')}" if missing.any?
    end
    Clickhouse.with { |conn| conn.insert('user_profiles', rows) }
  end

  # Insert rows into visitor_daily table.
  def insert_ch_visitor_daily(rows)
    rows = [rows] if rows.is_a?(Hash)
    Clickhouse.with { |conn| conn.insert('visitor_daily', rows) }
  end

  REQUIRED_SESSION_SUMMARY_KEYS = %i[project_id session_id visitor_id started_at ended_at].freeze

  # Insert rows into session_summary table.
  def insert_ch_session_summaries(rows)
    rows = [rows] if rows.is_a?(Hash)
    rows.each do |row|
      missing = REQUIRED_SESSION_SUMMARY_KEYS.reject { |k| row.key?(k) || row.key?(k.to_s) }
      raise ArgumentError, "Missing required session_summary fields: #{missing.join(', ')}" if missing.any?
      row[:event_date] ||= row[:started_at].to_date.to_s if row[:started_at]
    end
    Clickhouse.with { |conn| conn.insert('session_summary', rows) }
  end
end
