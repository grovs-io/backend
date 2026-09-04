# frozen_string_literal: true

require "test_helper"

class ClickhouseSchemaV2Test < ActiveSupport::TestCase
  include ClickhouseTestHelper

  setup do
    skip_unless_clickhouse!
  end

  BREAKDOWN_ROLLUPS = %i[
    project_breakdown link_breakdown visitor_breakdown country version source property billing
  ].freeze

  # The breakdown rollups are no longer MV-fed; they are rebuilt from canonical.
  # Rebuild exactly the partitions that hold canonical data for the project, so
  # the tests below stay date-agnostic and fast.
  def rebuild_breakdowns!(project_id)
    rows = Clickhouse.with do |conn|
      conn.select_all(
        "SELECT DISTINCT toYYYYMM(toDate(created_at)) AS p FROM events " \
        "WHERE project_id = #{Integer(project_id)}"
      )
    end
    rows.map { |r| r["p"].to_s }.each do |p|
      ClickhouseRollupRebuildService.rebuild_partition_range(p, p, rollups: BREAKDOWN_ROLLUPS)
    end
  end

  test "truncate_clickhouse_tables handles MVs without error" do
    assert_nothing_raised do
      truncate_clickhouse_tables
    end
  end

  test "events is the single deduped ReplacingMergeTree store" do
    result = Clickhouse.with do |conn|
      conn.select_one("SELECT engine, sorting_key FROM system.tables WHERE database = '#{Clickhouse.default_database}' AND name = 'events'")
    end
    assert_equal "ReplacingMergeTree", result['engine']
    # Dedup key = ORDER BY. event_id (deterministic content hash) is the trailing
    # key so byte-identical events collapse; visitor_id stays OUT (a skip index)
    # so retries/merges dedup regardless of visitor.
    assert_equal "project_id, toDate(created_at), event_type, event_id", result['sorting_key']
  end

  test "the old plain events table is gone (collapsed into the single store)" do
    result = Clickhouse.with do |conn|
      conn.select_one("SELECT name FROM system.tables WHERE database = '#{Clickhouse.default_database}' AND name = 'events_canonical'")
    end
    assert_nil result, "events_canonical must have been renamed to events (one table)"
  end

  test "collapse migration re-run is a safe no-op (does not drop the real events table)" do
    require Rails.root.join("db/clickhouse/migrate/20260701000002_collapse_to_single_events_table.rb")
    truncate_clickhouse_tables
    insert_ch_events({ project_id: 1, event_type: "view", created_at: "2026-05-01 00:00:00" })
    assert_equal 1, ch_event_count(1)

    # DB is already collapsed (events_canonical gone). Re-running up must early-return,
    # NOT DROP `events` (which IS the renamed canonical store) and NOT raise on the
    # missing RENAME source.
    migration = CollapseToSingleEventsTable.new(Clickhouse.connection, "collapse", 20_260_701_000_002)
    assert_nothing_raised { migration.up }

    assert_equal 1, ch_event_count(1), "events (the real store) must survive a migration re-run"
  end

  test "events table has event_id column" do
    result = Clickhouse.with do |conn|
      conn.select_one("SELECT name, type FROM system.columns WHERE database = '#{Clickhouse.default_database}' AND table = 'events' AND name = 'event_id'")
    end
    assert result, "event_id column should exist"
    assert_equal "String", result['type']
  end

  # --- project_daily MV ---

  test "project_daily table exists with AggregatingMergeTree engine" do
    result = Clickhouse.with do |conn|
      conn.select_one("SELECT engine FROM system.tables WHERE database = '#{Clickhouse.default_database}' AND name = 'project_daily'")
    end
    assert result, "project_daily table should exist"
    assert_equal "AggregatingMergeTree", result['engine']
  end

  test "mv_project_daily is dropped (project_daily is now rebuilt from canonical)" do
    result = Clickhouse.with do |conn|
      conn.select_one(
        "SELECT name FROM system.tables WHERE database = '#{Clickhouse.default_database}' " \
        "AND name = 'mv_project_daily' AND engine = 'MaterializedView'"
      )
    end
    assert_nil result, "mv_project_daily must be gone — project_daily is rebuilt from canonical, not MV-fed"
  end

  test "inserting event auto-populates project_daily via MV" do
    truncate_clickhouse_tables
    now = Time.current.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')

    insert_ch_events([
        {
          event_id: 'test-pd-1', project_id: 1, event_type: 'VIEW', device_id: 10,
          visitor_id: 20, link_id: 0, inviter_id: 0, campaign_id: 0,
          platform: 'ios', app_version: '', build: '', vendor_id: '', device_model: '',
          os: '', os_version: '', timezone: '', language: '', country: '', city: '',
          tracking_source: '', tracking_medium: '', tracking_campaign: '', ads_platform: '',
          link_tags: [], sdk_identifier: '', sdk_attributes: {}, session_id: '',
          engagement_time: 5000, properties: {}, tags: [], ip: '', remote_ip: '', path: '',
          created_at: now
        },
        {
          event_id: 'test-pd-2', project_id: 1, event_type: 'VIEW', device_id: 11,
          visitor_id: 21, link_id: 0, inviter_id: 0, campaign_id: 0,
          platform: 'ios', app_version: '', build: '', vendor_id: '', device_model: '',
          os: '', os_version: '', timezone: '', language: '', country: '', city: '',
          tracking_source: '', tracking_medium: '', tracking_campaign: '', ads_platform: '',
          link_tags: [], sdk_identifier: '', sdk_attributes: {}, session_id: '',
          engagement_time: 3000, properties: {}, tags: [], ip: '', remote_ip: '', path: '',
          created_at: now
        },
        {
          event_id: 'test-pd-3', project_id: 1, event_type: 'VIEW', device_id: 10,
          visitor_id: 20, link_id: 0, inviter_id: 0, campaign_id: 0,
          platform: 'ios', app_version: '', build: '', vendor_id: '', device_model: '',
          os: '', os_version: '', timezone: '', language: '', country: '', city: '',
          tracking_source: '', tracking_medium: '', tracking_campaign: '', ads_platform: '',
          link_tags: [], sdk_identifier: '', sdk_attributes: {}, session_id: '',
          engagement_time: 1000, properties: {}, tags: [], ip: '', remote_ip: '', path: '',
          created_at: now
        }
      ])
    rebuild_breakdowns!(1)

    row = Clickhouse.with do |conn|
      conn.select_one(<<~SQL)
        SELECT sum(cnt) AS total_cnt,
               sum(total_engagement_time) AS total_et,
               uniqMerge(visitors_state) AS unique_visitors,
               uniqMerge(devices_state) AS unique_devices
        FROM project_daily WHERE project_id = 1
      SQL
    end
    assert_equal 3, row['total_cnt']
    assert_equal 9000, row['total_et']
    assert_equal 2, row['unique_visitors'], "visitors_state should track 2 unique visitors (20, 21)"
    assert_equal 2, row['unique_devices'], "devices_state should track 2 unique devices (10, 11)"
  end

  # --- billing_active_visitors_daily MV ---

  test "billing_active_visitors_daily table exists with exact aggregate state" do
    table = Clickhouse.with do |conn|
      conn.select_one(
        "SELECT engine FROM system.tables WHERE database = '#{Clickhouse.default_database}' " \
        "AND name = 'billing_active_visitors_daily'"
      )
    end
    column = Clickhouse.with do |conn|
      conn.select_one(
        "SELECT type FROM system.columns WHERE database = '#{Clickhouse.default_database}' " \
        "AND table = 'billing_active_visitors_daily' AND name = 'visitors_state'"
      )
    end

    assert table, "billing_active_visitors_daily table should exist"
    assert_equal "AggregatingMergeTree", table['engine']
    assert_equal "AggregateFunction(uniqExact, UInt64)", column['type']
  end

  test "billing_active_visitors_daily materializes exact billing visitor population" do
    truncate_clickhouse_tables
    now = Time.current.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    base_event = {
      project_id: 1, link_id: 0, inviter_id: 0, campaign_id: 0,
      platform: 'ios', app_version: '', build: '', vendor_id: '', device_model: '',
      os: '', os_version: '', timezone: '', language: '', country: '', city: '',
      tracking_source: '', tracking_medium: '', tracking_campaign: '', ads_platform: '',
      link_tags: [], sdk_identifier: '', sdk_attributes: {}, session_id: '',
      engagement_time: 0, properties: {}, tags: [], ip: '', remote_ip: '', path: '',
      created_at: now
    }

    insert_ch_events([
      base_event.merge(event_id: 'test-bavd-1', event_type: Grovs::Events::OPEN, device_id: 10, visitor_id: 20),
      base_event.merge(event_id: 'test-bavd-2', event_type: Grovs::Events::CUSTOM, device_id: 11, visitor_id: 21),
      base_event.merge(event_id: 'test-bavd-3', event_type: Grovs::Events::SCREEN_VIEW, device_id: 12, visitor_id: 22),
      base_event.merge(event_id: 'test-bavd-4', event_type: Grovs::Events::INSTALL, device_id: 13, visitor_id: 0)
    ])
    insert_ch_events([
      base_event.merge(event_id: 'test-bavd-5', event_type: Grovs::Events::OPEN, device_id: 14, visitor_id: 20),
      base_event.merge(event_id: 'test-bavd-6', event_type: Grovs::Events::INSTALL, device_id: 15, visitor_id: 23)
    ])
    rebuild_breakdowns!(1)

    row = Clickhouse.with do |conn|
      conn.select_one(<<~SQL)
        SELECT uniqExactMerge(visitors_state) AS active_visitors
        FROM billing_active_visitors_daily
        WHERE project_id = 1
      SQL
    end

    assert_equal 2, row['active_visitors']
  end

  test "billing_active_visitors_daily counts every billable mapped event type" do
    truncate_clickhouse_tables
    now = Time.current.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')

    events = Grovs::Events::MAPPING.keys.each_with_index.map do |event_type, index|
      analytics_event(
        event_id: "billable-type-#{event_type}",
        event_type: event_type,
        visitor_id: 10_000 + index,
        device_id: 20_000 + index,
        created_at: now
      )
    end
    insert_ch_events(events)
    rebuild_breakdowns!(1)

    row = Clickhouse.with do |conn|
      conn.select_one(<<~SQL)
        SELECT uniqExactMerge(visitors_state) AS active_visitors
        FROM billing_active_visitors_daily
        WHERE project_id = 1
      SQL
    end

    assert_equal Grovs::Events::MAPPING.keys.size, row['active_visitors']
  end

  test "billing_active_visitors_daily exact backfill overlap does not double count" do
    truncate_clickhouse_tables

    table = "tmp_billing_active_visitors_daily_#{SecureRandom.hex(6)}"
    view = "mv_#{table}"

    Clickhouse.with do |conn|
      conn.execute("DROP TABLE IF EXISTS `#{view}`")
      conn.execute("DROP TABLE IF EXISTS `#{table}`")
      conn.execute(<<~SQL)
        CREATE TABLE `#{table}` (
          project_id UInt64,
          event_date Date,
          visitors_state AggregateFunction(uniqExact, UInt64)
        )
        ENGINE = AggregatingMergeTree()
        ORDER BY (project_id, event_date)
      SQL
      conn.execute(<<~SQL)
        CREATE MATERIALIZED VIEW `#{view}` TO `#{table}` AS
        SELECT
          project_id,
          toDate(created_at) AS event_date,
          uniqExactState(visitor_id) AS visitors_state
        FROM events
        WHERE visitor_id != 0
          AND event_type IN ('view','open','install','reinstall','time_spent','reactivation','app_open','user_referred')
        GROUP BY project_id, event_date
      SQL

      conn.insert('events', [
        analytics_event(
          event_id: 'billing-backfill-overlap',
          event_type: Grovs::Events::OPEN,
          visitor_id: 50_001,
          device_id: 60_001,
          created_at: '2026-05-01 10:00:00.000'
        )
      ])

      conn.execute(<<~SQL)
        INSERT INTO `#{table}`
        SELECT
          project_id,
          toDate(created_at) AS event_date,
          uniqExactState(visitor_id) AS visitors_state
        FROM events
        WHERE visitor_id != 0
          AND event_type IN ('view','open','install','reinstall','time_spent','reactivation','app_open','user_referred')
        GROUP BY project_id, event_date
      SQL

      row = conn.select_one(<<~SQL)
        SELECT uniqExactMerge(visitors_state) AS active_visitors
        FROM `#{table}`
        WHERE project_id = 1
      SQL

      assert_equal 1, row['active_visitors']
    end
  ensure
    Clickhouse.with do |conn|
      conn.execute("DROP TABLE IF EXISTS `#{view}`") if defined?(view) && view
      conn.execute("DROP TABLE IF EXISTS `#{table}`") if defined?(table) && table
    end if ClickhouseTestHelper.available?
  end

  # --- project_version_daily / project_source_daily / project_property_daily MVs ---

  test "analytics rollup tables exist" do
    %w[
      project_version_daily
      project_source_daily
      project_property_daily
    ].each do |table|
      result = Clickhouse.with do |conn|
        conn.select_one("SELECT engine FROM system.tables WHERE database = '#{Clickhouse.default_database}' AND name = '#{table}'")
      end
      assert result, "#{table} should exist"
      assert_equal "AggregatingMergeTree", result["engine"]
    end
  end

  test "project_version_daily materializes visitor counts and first_seen" do
    truncate_clickhouse_tables
    insert_ch_events([
      analytics_event(event_id: "ver-1", app_version: "1.0.0", visitor_id: 20, device_id: 10, created_at: "2026-05-01 10:00:00.000"),
      analytics_event(event_id: "ver-2", app_version: "1.0.0", visitor_id: 20, device_id: 10, created_at: "2026-05-02 10:00:00.000"),
      analytics_event(event_id: "ver-3", app_version: "2.0.0", visitor_id: 21, device_id: 11, created_at: "2026-05-03 10:00:00.000")
    ])
    rebuild_breakdowns!(1)

    rows = Clickhouse.with do |conn|
      conn.select_all(<<~SQL).to_a
        SELECT
          app_version,
          sum(cnt) AS cnt,
          uniqMerge(visitors_state) AS visitors,
          min(first_seen) AS first_seen
        FROM project_version_daily
        WHERE project_id = 1
        GROUP BY app_version
        ORDER BY app_version
      SQL
    end

    one = rows.find { |row| row["app_version"] == "1.0.0" }
    assert_equal 2, one["cnt"]
    assert_equal 1, one["visitors"]
    assert_equal "2026-05-01", one["first_seen"].to_s[0..9]
  end

  test "project_source_daily materializes current source classifier" do
    truncate_clickhouse_tables
    insert_ch_events([
      analytics_event(event_id: "src-campaign", visitor_id: 30, device_id: 30, campaign_id: 9),
      analytics_event(event_id: "src-referral", visitor_id: 31, device_id: 31, link_id: 100, sdk_generated: 1, link_visitor_id: 44),
      analytics_event(event_id: "src-api", visitor_id: 32, device_id: 32, link_id: 101, sdk_generated: 1, link_visitor_id: 0),
      analytics_event(event_id: "src-link", visitor_id: 33, device_id: 33, link_id: 102),
      analytics_event(event_id: "src-organic", visitor_id: 34, device_id: 34)
    ])
    rebuild_breakdowns!(1)

    rows = Clickhouse.with do |conn|
      conn.select_all(<<~SQL).to_a
        SELECT source, uniqMerge(visitors_state) AS visitors
        FROM project_source_daily
        WHERE project_id = 1
        GROUP BY source
      SQL
    end
    by_source = rows.to_h { |row| [row["source"], row["visitors"]] }

    assert_equal 1, by_source["campaigns"]
    assert_equal 1, by_source["referrals"]
    assert_equal 1, by_source["api_links"]
    assert_equal 1, by_source["links"]
    assert_equal 1, by_source["organic"]
  end

  test "project_property_daily materializes only allowlisted present keys" do
    truncate_clickhouse_tables
    insert_ch_events([
      analytics_event(event_id: "prop-plan", visitor_id: 40, device_id: 40, properties: { "plan" => "premium", "ignored" => "x" }),
      analytics_event(event_id: "prop-tier", visitor_id: 41, device_id: 41, properties: { "tier" => "gold" }),
      analytics_event(event_id: "prop-missing", visitor_id: 42, device_id: 42, properties: { "ignored" => "y" })
    ])
    rebuild_breakdowns!(1)

    rows = Clickhouse.with do |conn|
      conn.select_all(<<~SQL).to_a
        SELECT property_key, property_value, uniqMerge(visitors_state) AS visitors
        FROM project_property_daily
        WHERE project_id = 1
        GROUP BY property_key, property_value
        ORDER BY property_key, property_value
      SQL
    end

    assert_equal [["plan", "premium"], ["tier", "gold"]], rows.map { |row| [row["property_key"], row["property_value"]] }
    assert_equal [1, 1], rows.map { |row| row["visitors"] }
  end

  # --- link_daily MV ---

  test "link_daily table exists with SummingMergeTree engine" do
    result = Clickhouse.with do |conn|
      conn.select_one("SELECT engine FROM system.tables WHERE database = '#{Clickhouse.default_database}' AND name = 'link_daily'")
    end
    assert result, "link_daily table should exist"
    assert_equal "SummingMergeTree", result['engine']
  end

  test "mv_link_daily is dropped (link_daily is now rebuilt from canonical)" do
    result = Clickhouse.with do |conn|
      conn.select_one(
        "SELECT name FROM system.tables WHERE database = '#{Clickhouse.default_database}' " \
        "AND name = 'mv_link_daily' AND engine = 'MaterializedView'"
      )
    end
    assert_nil result, "mv_link_daily must be gone — link_daily is rebuilt from canonical, not MV-fed"
  end

  test "inserting event with link auto-populates link_daily" do
    truncate_clickhouse_tables
    now = Time.current.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')

    insert_ch_events([{
        event_id: 'test-ld-1', project_id: 1, event_type: 'VIEW', device_id: 10,
        visitor_id: 20, link_id: 300, inviter_id: 0, campaign_id: 50,
        platform: 'ios', app_version: '', build: '', vendor_id: '', device_model: '',
        os: '', os_version: '', timezone: '', language: '', country: '', city: '',
        tracking_source: '', tracking_medium: '', tracking_campaign: '', ads_platform: '',
        link_tags: [], sdk_identifier: '', sdk_attributes: {}, session_id: '',
        engagement_time: 0, properties: {}, tags: [], ip: '', remote_ip: '', path: '',
        created_at: now
      }])
    rebuild_breakdowns!(1)

    row = Clickhouse.with do |conn|
      conn.select_one("SELECT sum(cnt) AS total FROM link_daily WHERE project_id = 1 AND link_id = 300")
    end
    assert_equal 1, row['total']
  end

  test "event without link does not populate link_daily" do
    truncate_clickhouse_tables
    now = Time.current.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')

    insert_ch_events([{
        event_id: 'test-ld-nolink', project_id: 1, event_type: 'OPEN', device_id: 10,
        visitor_id: 20, link_id: 0, inviter_id: 0, campaign_id: 0,
        platform: 'ios', app_version: '', build: '', vendor_id: '', device_model: '',
        os: '', os_version: '', timezone: '', language: '', country: '', city: '',
        tracking_source: '', tracking_medium: '', tracking_campaign: '', ads_platform: '',
        link_tags: [], sdk_identifier: '', sdk_attributes: {}, session_id: '',
        engagement_time: 0, properties: {}, tags: [], ip: '', remote_ip: '', path: '',
        created_at: now
      }])
    rebuild_breakdowns!(1)

    count = Clickhouse.with do |conn|
      conn.select_value("SELECT count() FROM link_daily WHERE project_id = 1")
    end
    assert_equal 0, count, "Events with link_id=0 should not populate link_daily"
  end

  # --- visitor_daily MV ---

  test "visitor_daily table exists with AggregatingMergeTree engine" do
    result = Clickhouse.with do |conn|
      conn.select_one("SELECT engine FROM system.tables WHERE database = '#{Clickhouse.default_database}' AND name = 'visitor_daily'")
    end
    assert result, "visitor_daily table should exist"
    assert_equal "AggregatingMergeTree", result['engine']
  end

  test "mv_visitor_daily is dropped (visitor_daily is now rebuilt from canonical)" do
    result = Clickhouse.with do |conn|
      conn.select_one(
        "SELECT name FROM system.tables WHERE database = '#{Clickhouse.default_database}' " \
        "AND name = 'mv_visitor_daily' AND engine = 'MaterializedView'"
      )
    end
    assert_nil result, "mv_visitor_daily must be gone — visitor_daily is rebuilt from canonical, not MV-fed"
  end

  test "inserting event auto-populates visitor_daily with correct inviter" do
    truncate_clickhouse_tables
    now = Time.current.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')

    insert_ch_events([{
        event_id: 'test-vd-1', project_id: 1, event_type: 'OPEN', device_id: 10,
        visitor_id: 42, link_id: 0, inviter_id: 99, campaign_id: 0,
        platform: 'android', app_version: '', build: '', vendor_id: '', device_model: '',
        os: '', os_version: '', timezone: '', language: '', country: '', city: '',
        tracking_source: '', tracking_medium: '', tracking_campaign: '', ads_platform: '',
        link_tags: [], sdk_identifier: '', sdk_attributes: {}, session_id: '',
        engagement_time: 1200, properties: {}, tags: [], ip: '', remote_ip: '', path: '',
        created_at: now
      }])
    rebuild_breakdowns!(1)

    row = Clickhouse.with do |conn|
      conn.select_one(
        "SELECT sum(cnt) AS total_cnt, max(inviter_id_state) AS inviter_id " \
        "FROM visitor_daily WHERE project_id = 1 AND visitor_id = 42"
      )
    end
    assert_equal 1, row['total_cnt']
    assert_equal 99, row['inviter_id']
  end

  # --- purchase MVs ---

  test "purchase_project_daily table exists" do
    result = Clickhouse.with do |conn|
      conn.select_one("SELECT engine FROM system.tables WHERE database = '#{Clickhouse.default_database}' AND name = 'purchase_project_daily'")
    end
    assert result, "purchase_project_daily should exist"
    assert_equal "ReplacingMergeTree", result['engine']
  end

  test "purchase_product_daily table exists" do
    result = Clickhouse.with do |conn|
      conn.select_one("SELECT engine FROM system.tables WHERE database = '#{Clickhouse.default_database}' AND name = 'purchase_product_daily'")
    end
    assert result, "purchase_product_daily should exist"
    assert_equal "ReplacingMergeTree", result['engine']
  end

  test "inserting purchase event auto-populates both purchase MVs" do
    truncate_clickhouse_tables
    now = Time.current.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')

    Clickhouse.with do |conn|
      conn.insert('purchase_events', [
        {
          project_id: 1, event_type: 'buy', purchase_type: 'subscription',
          product_id: 'com.app.pro', usd_price_cents: 999, currency: 'USD',
          quantity: 1, transaction_id: 'txn_mv_test_1', original_transaction_id: '',
          store_source: 'apple', device_id: 10, link_id: 0, visitor_id: 20,
          purchase_date: now, created_at: now
        },
        {
          project_id: 1, event_type: 'buy', purchase_type: 'one_time',
          product_id: 'com.app.pro', usd_price_cents: 499, currency: 'USD',
          quantity: 1, transaction_id: 'txn_mv_test_2', original_transaction_id: '',
          store_source: 'apple', device_id: 11, link_id: 0, visitor_id: 21,
          purchase_date: now, created_at: now
        },
        {
          project_id: 1, event_type: 'buy', purchase_type: 'subscription',
          product_id: 'com.app.pro', usd_price_cents: 999, currency: 'USD',
          quantity: 1, transaction_id: 'txn_mv_test_3', original_transaction_id: '',
          store_source: 'apple', device_id: 10, link_id: 0, visitor_id: 20,
          purchase_date: now, created_at: now
        }
      ])
    end

    proj_row = Clickhouse.with do |conn|
      conn.select_one(<<~SQL)
        SELECT sum(total_revenue_cents) AS rev, sum(units) AS u,
               uniqExact(visitor_id) AS paying_visitors,
               store_source
        FROM purchase_project_daily FINAL WHERE project_id = 1 GROUP BY store_source
      SQL
    end
    assert_equal 2497, proj_row['rev']
    assert_equal 3, proj_row['u']
    assert_equal 2, proj_row['paying_visitors'], "paying_visitors_state should track 2 unique visitors (20, 21)"
    assert_equal 'apple', proj_row['store_source']

    prod_row = Clickhouse.with do |conn|
      conn.select_one(
        "SELECT sum(total_revenue_cents) AS rev, store_source " \
        "FROM purchase_product_daily WHERE project_id = 1 AND product_id = 'com.app.pro' " \
        "GROUP BY store_source"
      )
    end
    assert_equal 2497, prod_row['rev']
    assert_equal 'apple', prod_row['store_source']
  end

  test "purchase_project_daily keeps the newest correction for a replayed transaction" do
    truncate_clickhouse_tables

    Clickhouse.with do |conn|
      conn.insert('purchase_events', [
        {
          project_id: 1, event_type: 'buy', purchase_type: 'subscription',
          product_id: 'com.app.pro', usd_price_cents: 999, currency: 'USD',
          quantity: 1, transaction_id: 'txn_purchase_correction', original_transaction_id: '',
          store_source: 'apple', device_id: 10, link_id: 0, visitor_id: 20,
          purchase_date: '2026-05-01 10:00:00.000', created_at: '2026-05-01 10:00:00.000'
        },
        {
          project_id: 1, event_type: 'buy', purchase_type: 'subscription',
          product_id: 'com.app.pro', usd_price_cents: 1499, currency: 'USD',
          quantity: 1, transaction_id: 'txn_purchase_correction', original_transaction_id: '',
          store_source: 'apple', device_id: 10, link_id: 0, visitor_id: 20,
          purchase_date: '2026-05-01 10:00:00.000', created_at: '2026-05-02 10:00:00.000'
        }
      ])
    end

    row = Clickhouse.with do |conn|
      conn.select_one(<<~SQL)
        SELECT sum(total_revenue_cents) AS revenue, sum(units) AS units
        FROM purchase_project_daily FINAL
        WHERE project_id = 1 AND transaction_id = 'txn_purchase_correction'
      SQL
    end

    assert_equal 1499, row['revenue']
    assert_equal 1, row['units']
  end

  # --- project_country_daily MV ---

  test "project_country_daily table exists with AggregatingMergeTree engine" do
    result = Clickhouse.with do |conn|
      conn.select_one("SELECT engine FROM system.tables WHERE database = '#{Clickhouse.default_database}' AND name = 'project_country_daily'")
    end
    assert result, "project_country_daily table should exist"
    assert_equal "AggregatingMergeTree", result['engine']
  end

  test "mv_project_country_daily is dropped (project_country_daily is now rebuilt from canonical)" do
    result = Clickhouse.with do |conn|
      conn.select_one(
        "SELECT name FROM system.tables WHERE database = '#{Clickhouse.default_database}' " \
        "AND name = 'mv_project_country_daily' AND engine = 'MaterializedView'"
      )
    end
    assert_nil result, "mv_project_country_daily must be gone — rebuilt from canonical, not MV-fed"
  end

  test "inserting event with country auto-populates project_country_daily" do
    truncate_clickhouse_tables
    now = Time.current.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')

    insert_ch_events([
        {
          event_id: 'test-pcd-1', project_id: 1, event_type: 'VIEW', device_id: 10,
          visitor_id: 20, link_id: 0, inviter_id: 0, campaign_id: 0,
          platform: 'ios', app_version: '', build: '', vendor_id: '', device_model: '',
          os: '', os_version: '', timezone: '', language: '', country: 'US', city: '',
          tracking_source: '', tracking_medium: '', tracking_campaign: '', ads_platform: '',
          link_tags: [], sdk_identifier: '', sdk_attributes: {}, session_id: '',
          engagement_time: 0, properties: {}, tags: [], ip: '', remote_ip: '', path: '',
          created_at: now
        },
        {
          event_id: 'test-pcd-2', project_id: 1, event_type: 'VIEW', device_id: 11,
          visitor_id: 21, link_id: 0, inviter_id: 0, campaign_id: 0,
          platform: 'android', app_version: '', build: '', vendor_id: '', device_model: '',
          os: '', os_version: '', timezone: '', language: '', country: 'DE', city: '',
          tracking_source: '', tracking_medium: '', tracking_campaign: '', ads_platform: '',
          link_tags: [], sdk_identifier: '', sdk_attributes: {}, session_id: '',
          engagement_time: 0, properties: {}, tags: [], ip: '', remote_ip: '', path: '',
          created_at: now
        },
        {
          event_id: 'test-pcd-3', project_id: 1, event_type: 'OPEN', device_id: 12,
          visitor_id: 22, link_id: 0, inviter_id: 0, campaign_id: 0,
          platform: 'ios', app_version: '', build: '', vendor_id: '', device_model: '',
          os: '', os_version: '', timezone: '', language: '', country: 'US', city: '',
          tracking_source: '', tracking_medium: '', tracking_campaign: '', ads_platform: '',
          link_tags: [], sdk_identifier: '', sdk_attributes: {}, session_id: '',
          engagement_time: 0, properties: {}, tags: [], ip: '', remote_ip: '', path: '',
          created_at: now
        }
      ])
    rebuild_breakdowns!(1)

    us_row = Clickhouse.with do |conn|
      conn.select_one("SELECT sum(cnt) AS total, uniqMerge(visitors_state) AS visitors FROM project_country_daily WHERE project_id = 1 AND country = 'US'")
    end
    assert_equal 2, us_row['total']
    assert_equal 2, us_row['visitors']

    de_row = Clickhouse.with do |conn|
      conn.select_one("SELECT sum(cnt) AS total FROM project_country_daily WHERE project_id = 1 AND country = 'DE'")
    end
    assert_equal 1, de_row['total']
  end

  private

  def analytics_event(attrs = {})
    {
      event_id: attrs.fetch(:event_id),
      project_id: attrs.fetch(:project_id, 1),
      event_type: attrs.fetch(:event_type, Grovs::Events::OPEN),
      event_name: attrs.fetch(:event_name, ''),
      screen_name: attrs.fetch(:screen_name, ''),
      device_id: attrs.fetch(:device_id, 10),
      visitor_id: attrs.fetch(:visitor_id, 20),
      link_id: attrs.fetch(:link_id, 0),
      inviter_id: attrs.fetch(:inviter_id, 0),
      campaign_id: attrs.fetch(:campaign_id, 0),
      platform: attrs.fetch(:platform, 'ios'),
      app_version: attrs.fetch(:app_version, '1.0.0'),
      build: attrs.fetch(:build, ''),
      vendor_id: attrs.fetch(:vendor_id, ''),
      device_model: attrs.fetch(:device_model, ''),
      os: attrs.fetch(:os, ''),
      os_version: attrs.fetch(:os_version, ''),
      timezone: attrs.fetch(:timezone, ''),
      language: attrs.fetch(:language, ''),
      country: attrs.fetch(:country, ''),
      city: attrs.fetch(:city, ''),
      tracking_source: attrs.fetch(:tracking_source, ''),
      tracking_medium: attrs.fetch(:tracking_medium, ''),
      tracking_campaign: attrs.fetch(:tracking_campaign, ''),
      ads_platform: attrs.fetch(:ads_platform, ''),
      link_tags: attrs.fetch(:link_tags, []),
      sdk_identifier: attrs.fetch(:sdk_identifier, ''),
      sdk_attributes: attrs.fetch(:sdk_attributes, {}),
      session_id: attrs.fetch(:session_id, ''),
      engagement_time: attrs.fetch(:engagement_time, 0),
      properties: attrs.fetch(:properties, {}),
      tags: attrs.fetch(:tags, []),
      ip: attrs.fetch(:ip, ''),
      remote_ip: attrs.fetch(:remote_ip, ''),
      path: attrs.fetch(:path, ''),
      sdk_generated: attrs.fetch(:sdk_generated, 0),
      link_visitor_id: attrs.fetch(:link_visitor_id, 0),
      created_at: attrs.fetch(:created_at, Time.current.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'))
    }
  end
end
