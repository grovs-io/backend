# frozen_string_literal: true

require 'test_helper'

class ClickhouseSmokeTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  # Fixed timestamp avoids Time.now non-determinism (month boundaries, etc.)
  FIXED_TS = '2025-06-15 12:00:00'

  setup do
    skip_unless_clickhouse!
  end

  # ---------------------------------------------------------------------------
  # Schema validation — all 3 tables exist with expected columns and types
  # ---------------------------------------------------------------------------

  test "events table has all expected columns with correct types" do
    columns = describe_table('events')

    assert_column columns, 'event_id',          'String'
    assert_column columns, 'project_id',        'UInt64'
    assert_column columns, 'event_type',        'LowCardinality(String)'
    assert_column columns, 'event_name',        'String'
    assert_column columns, 'device_id',         'UInt64'
    assert_column columns, 'visitor_id',        'UInt64'
    assert_column columns, 'link_id',           'UInt64'
    assert_column columns, 'inviter_id',        'UInt64'
    assert_column columns, 'campaign_id',       'UInt64'
    assert_column columns, 'platform',          'LowCardinality(String)'
    assert_column columns, 'app_version',       'String'
    assert_column columns, 'build',             'String'
    assert_column columns, 'vendor_id',         'String'
    assert_column columns, 'device_model',      'String'
    assert_column columns, 'os',                'LowCardinality(String)'
    assert_column columns, 'os_version',        'String'
    assert_column columns, 'timezone',          'String'
    assert_column columns, 'language',          'LowCardinality(String)'
    assert_column columns, 'country',           'LowCardinality(String)'
    assert_column columns, 'city',              'String'
    assert_column columns, 'tracking_source',   'LowCardinality(String)'
    assert_column columns, 'tracking_medium',   'LowCardinality(String)'
    assert_column columns, 'tracking_campaign', 'String'
    assert_column columns, 'ads_platform',      'LowCardinality(String)'
    assert_column columns, 'link_tags',         'Array(LowCardinality(String))'
    assert_column columns, 'sdk_identifier',    'String'
    assert_column columns, 'sdk_attributes',    'JSON'
    assert_column columns, 'session_id',        'String'
    assert_column columns, 'engagement_time',   'UInt64'
    assert_column columns, 'properties',        'JSON'
    assert_column columns, 'tags',              'Array(LowCardinality(String))'
    assert_column columns, 'ip',                'String'
    assert_column columns, 'remote_ip',         'String'
    assert_column columns, 'path',              'String'
    assert_column columns, 'created_at',        'DateTime64(3, \'UTC\')'
  end

  test "purchase_events table has all expected columns with correct types" do
    columns = describe_table('purchase_events')

    assert_column columns, 'project_id',              'UInt64'
    assert_column columns, 'event_type',              'LowCardinality(String)'
    assert_column columns, 'purchase_type',           'LowCardinality(String)'
    assert_column columns, 'product_id',              'String'
    assert_column columns, 'usd_price_cents',         'Int64'
    assert_column columns, 'currency',                'LowCardinality(String)'
    assert_column columns, 'quantity',                'UInt32'
    assert_column columns, 'transaction_id',          'String'
    assert_column columns, 'original_transaction_id', 'String'
    assert_column columns, 'store_source',            'LowCardinality(String)'
    assert_column columns, 'device_id',               'UInt64'
    assert_column columns, 'link_id',                 'UInt64'
    assert_column columns, 'visitor_id',              'UInt64'
    assert_column columns, 'purchase_date',           'DateTime64(3, \'UTC\')'
    assert_column columns, 'created_at',              'DateTime64(3, \'UTC\')'
  end

  test "user_profiles table has all expected columns with correct types" do
    columns = describe_table('user_profiles')

    assert_column columns, 'project_id',     'UInt64'
    assert_column columns, 'visitor_id',     'UInt64'
    assert_column columns, 'sdk_identifier', 'String'
    assert_column columns, 'properties',     'JSON'
    assert_column columns, 'first_seen',     'DateTime64(3, \'UTC\')'
    assert_column columns, 'last_seen',      'DateTime64(3, \'UTC\')'
    assert_column columns, 'country',        'LowCardinality(String)'
    assert_column columns, 'platform',       'LowCardinality(String)'
    assert_column columns, 'inviter_id',     'UInt64'
  end

  # ---------------------------------------------------------------------------
  # Engine and partitioning validation
  # ---------------------------------------------------------------------------

  test "events table uses ReplacingMergeTree with monthly partitioning" do
    engine = table_engine('events')
    assert_equal 'ReplacingMergeTree', engine
    # Verify partitioning by inserting events in different months
    insert_ch_events([
      { project_id: 1, event_type: 'view', created_at: '2025-01-15 00:00:00' },
      { project_id: 1, event_type: 'view', created_at: '2025-02-15 00:00:00' }
    ])
    partitions = partition_count('events')
    assert_equal 2, partitions, 'Events in different months should land in different partitions'
  end

  test "purchase_events table uses ReplacingMergeTree" do
    engine = table_engine('purchase_events')
    assert_equal 'ReplacingMergeTree', engine
  end

  test "user_profiles table uses ReplacingMergeTree" do
    engine = table_engine('user_profiles')
    assert_equal 'ReplacingMergeTree', engine
  end

  # ---------------------------------------------------------------------------
  # Events: insert/read roundtrip
  # ---------------------------------------------------------------------------

  test "insert and read back a single event with all fields" do
    insert_ch_events({
      project_id: 42,
      event_type: 'view',
      event_name: 'screen_view',
      device_id: 100,
      visitor_id: 200,
      link_id: 300,
      inviter_id: 400,
      campaign_id: 500,
      platform: 'ios',
      app_version: '2.1.0',
      build: '1234',
      vendor_id: 'ABC-DEF',
      device_model: 'iPhone 15',
      os: 'iOS',
      os_version: '17.4',
      timezone: 'America/New_York',
      language: 'en',
      country: 'US',
      city: 'New York',
      tracking_source: 'facebook',
      tracking_medium: 'cpc',
      tracking_campaign: 'spring_sale',
      ads_platform: 'meta',
      link_tags: %w[promo featured],
      sdk_identifier: 'user-123',
      sdk_attributes: { plan: 'premium', score: 42 },
      session_id: 'sess-abc-123',
      engagement_time: 5000,
      properties: { screen: 'home', tab: 'feed' },
      tags: %w[organic mobile],
      ip: '203.0.113.1',
      remote_ip: '198.51.100.1',
      path: '/summer-sale',
      created_at: FIXED_TS
    })

    result = ch_select_events(42)
    assert_equal 1, result.to_a.size

    row = result.to_a.first
    assert_equal 42, row['project_id']
    assert_equal 'view', row['event_type']
    assert_equal 'screen_view', row['event_name']
    assert_equal 100, row['device_id']
    assert_equal 200, row['visitor_id']
    assert_equal 300, row['link_id']
    assert_equal 400, row['inviter_id']
    assert_equal 500, row['campaign_id']
    assert_equal 'ios', row['platform']
    assert_equal '2.1.0', row['app_version']
    assert_equal 'iPhone 15', row['device_model']
    assert_equal 'iOS', row['os']
    assert_equal 'US', row['country']
    assert_equal 'New York', row['city']
    assert_equal 'facebook', row['tracking_source']
    assert_equal 'cpc', row['tracking_medium']
    assert_equal 'meta', row['ads_platform']
    assert_equal 'user-123', row['sdk_identifier']
    assert_equal 'sess-abc-123', row['session_id']
    assert_equal 5000, row['engagement_time']
    assert_equal '203.0.113.1', row['ip']
    assert_equal '/summer-sale', row['path']
  end

  test "insert multiple events and count by type" do
    insert_ch_events([
      { project_id: 1, event_type: 'view', created_at: FIXED_TS },
      { project_id: 1, event_type: 'view', created_at: FIXED_TS },
      { project_id: 1, event_type: 'open', created_at: FIXED_TS },
      { project_id: 1, event_type: 'install', created_at: FIXED_TS },
      { project_id: 2, event_type: 'view', created_at: FIXED_TS }
    ])

    assert_equal 4, ch_event_count(1)
    assert_equal 2, ch_event_count(1, event_type: 'view')
    assert_equal 1, ch_event_count(1, event_type: 'open')
    assert_equal 1, ch_event_count(1, event_type: 'install')
    assert_equal 0, ch_event_count(1, event_type: 'app_open')
    assert_equal 1, ch_event_count(2)
  end

  test "events are isolated by project_id" do
    insert_ch_events([
      { project_id: 10, event_type: 'view', created_at: FIXED_TS },
      { project_id: 20, event_type: 'view', created_at: FIXED_TS }
    ])

    result_10 = ch_select_events(10)
    result_20 = ch_select_events(20)
    result_99 = ch_select_events(99)

    assert_equal 1, result_10.to_a.size
    assert_equal 1, result_20.to_a.size
    assert_equal 0, result_99.to_a.size
  end

  # ---------------------------------------------------------------------------
  # JSON columns — native JSON type roundtrip
  # ---------------------------------------------------------------------------

  test "properties JSON column stores and retrieves structured data" do
    insert_ch_events({
      project_id: 1,
      event_type: 'screen_view',
      properties: { screen_name: 'HomeViewController', tab_index: 2, is_premium: true },
      created_at: FIXED_TS
    })

    row = Clickhouse.with do |conn|
      conn.select_one("SELECT properties FROM events WHERE project_id = 1")
    end

    props = row['properties']
    assert_equal 'HomeViewController', props['screen_name']
    assert_equal 2, props['tab_index']
    assert_equal true, props['is_premium']
  end

  test "sdk_attributes JSON column stores and retrieves structured data" do
    insert_ch_events({
      project_id: 1,
      event_type: 'view',
      sdk_attributes: { user_level: 'gold', account_age_days: 365 },
      created_at: FIXED_TS
    })

    row = Clickhouse.with do |conn|
      conn.select_one("SELECT sdk_attributes FROM events WHERE project_id = 1")
    end

    attrs = row['sdk_attributes']
    assert_equal 'gold', attrs['user_level']
    assert_equal 365, attrs['account_age_days']
  end

  test "JSON columns can be queried with dot notation" do
    insert_ch_events([
      { project_id: 1, event_type: 'view', properties: { screen: 'home' }, created_at: FIXED_TS },
      { project_id: 1, event_type: 'view', properties: { screen: 'settings' }, created_at: FIXED_TS },
      { project_id: 1, event_type: 'view', properties: { screen: 'home' }, created_at: FIXED_TS }
    ])

    count = Clickhouse.with do |conn|
      conn.select_value("SELECT COUNT(*) FROM events WHERE project_id = 1 AND properties.screen = 'home'")
    end

    assert_equal 2, count
  end

  # ---------------------------------------------------------------------------
  # Array columns — tags and link_tags
  # ---------------------------------------------------------------------------

  test "array columns store and retrieve string arrays" do
    insert_ch_events({
      project_id: 1,
      event_type: 'view',
      tags: %w[organic mobile premium],
      link_tags: %w[promo summer],
      created_at: FIXED_TS
    })

    row = Clickhouse.with do |conn|
      conn.select_one("SELECT tags, link_tags FROM events WHERE project_id = 1")
    end

    assert_includes row['tags'], 'organic'
    assert_includes row['tags'], 'mobile'
    assert_includes row['tags'], 'premium'
    assert_equal 3, row['tags'].size

    assert_includes row['link_tags'], 'promo'
    assert_includes row['link_tags'], 'summer'
    assert_equal 2, row['link_tags'].size
  end

  test "array columns can be filtered with has() function" do
    insert_ch_events([
      { project_id: 1, event_type: 'view', tags: %w[organic], created_at: FIXED_TS },
      { project_id: 1, event_type: 'view', tags: %w[paid], created_at: FIXED_TS },
      { project_id: 1, event_type: 'view', tags: %w[organic paid], created_at: FIXED_TS }
    ])

    organic_count = Clickhouse.with do |conn|
      conn.select_value("SELECT COUNT(*) FROM events WHERE project_id = 1 AND has(tags, 'organic')")
    end

    assert_equal 2, organic_count
  end

  # ---------------------------------------------------------------------------
  # Purchase events: insert + ReplacingMergeTree dedup with FINAL
  # ---------------------------------------------------------------------------

  test "purchase_events insert and read roundtrip" do
    Clickhouse.with do |conn|
      conn.insert('purchase_events', [{
        project_id: 1,
        event_type: 'buy',
        purchase_type: 'subscription',
        product_id: 'com.app.premium',
        usd_price_cents: 999,
        currency: 'USD',
        quantity: 1,
        transaction_id: 'txn-001',
        original_transaction_id: 'txn-orig-001',
        store_source: 'apple',
        device_id: 10,
        link_id: 20,
        visitor_id: 30,
        purchase_date: FIXED_TS,
        created_at: FIXED_TS
      }])
    end

    row = Clickhouse.with do |conn|
      conn.select_one("SELECT * FROM purchase_events FINAL WHERE project_id = 1")
    end

    assert_equal 1, row['project_id']
    assert_equal 'buy', row['event_type']
    assert_equal 'subscription', row['purchase_type']
    assert_equal 'com.app.premium', row['product_id']
    assert_equal 999, row['usd_price_cents']
    assert_equal 'txn-001', row['transaction_id']
    assert_equal 'apple', row['store_source']
  end

  test "purchase_events deduplicates with FINAL keeping latest created_at" do
    Clickhouse.with do |conn|
      # Insert original purchase
      conn.insert('purchase_events', [{
        project_id: 1,
        event_type: 'buy',
        transaction_id: 'txn-dup',
        usd_price_cents: 999,
        purchase_date: '2025-01-15 10:00:00',
        created_at: '2025-01-15 10:00:00'
      }])

      # Insert duplicate with updated price (webhook retry with correction)
      conn.insert('purchase_events', [{
        project_id: 1,
        event_type: 'buy',
        transaction_id: 'txn-dup',
        usd_price_cents: 1299,
        purchase_date: '2025-01-15 10:00:00',
        created_at: '2025-01-15 10:01:00'
      }])

      # No OPTIMIZE — queries use FINAL to handle un-merged state,
      # which is how application code must work too.
      count = conn.select_value(
        "SELECT COUNT(*) FROM purchase_events FINAL WHERE project_id = 1 AND transaction_id = 'txn-dup'"
      )
      assert_equal 1, count, 'FINAL should deduplicate to a single row'

      row = conn.select_one(
        "SELECT usd_price_cents FROM purchase_events FINAL WHERE project_id = 1 AND transaction_id = 'txn-dup'"
      )
      assert_equal 1299, row['usd_price_cents'], 'FINAL should keep the row with latest created_at'
    end
  end

  test "purchase_events shows duplicates without FINAL before merge — FINAL is required" do
    Clickhouse.with do |conn|
      # Insert two rows with the same ORDER BY key (project_id, transaction_id, event_type)
      conn.insert('purchase_events', [{
        project_id: 1,
        event_type: 'buy',
        transaction_id: 'txn-no-final',
        usd_price_cents: 500,
        purchase_date: '2025-01-15 10:00:00',
        created_at: '2025-01-15 10:00:00'
      }])

      conn.insert('purchase_events', [{
        project_id: 1,
        event_type: 'buy',
        transaction_id: 'txn-no-final',
        usd_price_cents: 700,
        purchase_date: '2025-01-15 10:00:00',
        created_at: '2025-01-15 10:01:00'
      }])

      # WITHOUT FINAL: duplicates are visible (ClickHouse has not merged yet)
      count_without_final = conn.select_value(
        "SELECT COUNT(*) FROM purchase_events WHERE project_id = 1 AND transaction_id = 'txn-no-final'"
      )
      assert count_without_final >= 2,
             "Without FINAL, duplicate rows should be visible before merge (got #{count_without_final}). " \
             "This documents why FINAL is REQUIRED on all purchase_events reads."

      # WITH FINAL: dedup applied at query time regardless of merge state
      count_with_final = conn.select_value(
        "SELECT COUNT(*) FROM purchase_events FINAL WHERE project_id = 1 AND transaction_id = 'txn-no-final'"
      )
      assert_equal 1, count_with_final,
                   'FINAL deduplicates at query time even before background merge runs'
    end
  end

  # ---------------------------------------------------------------------------
  # User profiles: insert + ReplacingMergeTree upsert
  # ---------------------------------------------------------------------------

  test "user_profiles insert and read roundtrip" do
    Clickhouse.with do |conn|
      conn.insert('user_profiles', [{
        project_id: 1,
        visitor_id: 42,
        sdk_identifier: 'user@example.com',
        properties: { name: 'Alice', tier: 'premium' },
        first_seen: '2025-01-01 00:00:00',
        last_seen: '2025-06-15 12:00:00',
        country: 'US',
        platform: 'ios',
        inviter_id: 99
      }])

      row = conn.select_one("SELECT * FROM user_profiles FINAL WHERE project_id = 1 AND visitor_id = 42")

      assert_equal 1, row['project_id']
      assert_equal 42, row['visitor_id']
      assert_equal 'user@example.com', row['sdk_identifier']
      assert_equal 'US', row['country']
      assert_equal 'ios', row['platform']
      assert_equal 99, row['inviter_id']

      props = row['properties']
      assert_equal 'Alice', props['name']
      assert_equal 'premium', props['tier']
    end
  end

  test "user_profiles upserts keep latest last_seen" do
    Clickhouse.with do |conn|
      conn.insert('user_profiles', [{
        project_id: 1, visitor_id: 100,
        sdk_identifier: 'old-id',
        properties: { level: 1 },
        first_seen: '2025-01-01 00:00:00',
        last_seen: '2025-01-01 00:00:00',
        country: 'US', platform: 'ios'
      }])

      conn.insert('user_profiles', [{
        project_id: 1, visitor_id: 100,
        sdk_identifier: 'new-id',
        properties: { level: 5 },
        first_seen: '2025-01-01 00:00:00',
        last_seen: '2025-06-01 00:00:00',
        country: 'DE', platform: 'android'
      }])

      row = conn.select_one("SELECT * FROM user_profiles FINAL WHERE project_id = 1 AND visitor_id = 100")

      assert_equal 'new-id', row['sdk_identifier'], 'Should keep the row with latest last_seen'
      assert_equal 'DE', row['country']
      assert_equal 'android', row['platform']
    end
  end

  # ---------------------------------------------------------------------------
  # Truncation — clean slate between tests
  # ---------------------------------------------------------------------------

  test "truncate_clickhouse_tables empties all tables" do
    insert_ch_events({ project_id: 1, event_type: 'view', created_at: FIXED_TS })
    Clickhouse.with do |conn|
      conn.insert('purchase_events', [{
        project_id: 1, event_type: 'buy', transaction_id: 'txn-1',
        purchase_date: FIXED_TS, created_at: FIXED_TS
      }])
      conn.insert('user_profiles', [{
        project_id: 1, visitor_id: 1,
        first_seen: FIXED_TS, last_seen: FIXED_TS
      }])
    end

    assert_operator ch_event_count(1), :>, 0

    truncate_clickhouse_tables

    assert_equal 0, ch_event_count(1)
    Clickhouse.with do |conn|
      assert_equal 0, conn.select_value("SELECT COUNT(*) FROM purchase_events")
      assert_equal 0, conn.select_value("SELECT COUNT(*) FROM user_profiles")
    end
  end

  # ---------------------------------------------------------------------------
  # Helper validation
  # ---------------------------------------------------------------------------

  test "insert_ch_events rejects rows missing required fields" do
    assert_raises(ArgumentError) { insert_ch_events({ event_type: 'view', created_at: FIXED_TS }) }
    assert_raises(ArgumentError) { insert_ch_events({ project_id: 1, created_at: FIXED_TS }) }
    assert_raises(ArgumentError) { insert_ch_events({ project_id: 1, event_type: 'view' }) }
    assert_raises(ArgumentError) { insert_ch_events({}) }
  end

  test "ch_event_count handles event_type containing single quotes" do
    insert_ch_events([
      { project_id: 1, event_type: "it's_a_test", created_at: FIXED_TS },
      { project_id: 1, event_type: "it's_a_test", created_at: FIXED_TS },
      { project_id: 1, event_type: 'normal', created_at: FIXED_TS }
    ])

    assert_equal 2, ch_event_count(1, event_type: "it's_a_test")
    assert_equal 1, ch_event_count(1, event_type: 'normal')
  end

  test "insert_ch_events accepts string keys" do
    insert_ch_events({ 'project_id' => 1, 'event_type' => 'view', 'created_at' => FIXED_TS })

    assert_equal 1, ch_event_count(1, event_type: 'view')
  end

  test "ch_select_events rejects invalid column names" do
    assert_raises(ArgumentError) { ch_select_events(1, columns: ['valid', 'DROP TABLE events']) }
    assert_raises(ArgumentError) { ch_select_events(1, columns: ['foo; bar']) }
  end

  test "ch_select_events accepts valid column names" do
    insert_ch_events({ project_id: 1, event_type: 'view', platform: 'ios', created_at: FIXED_TS })

    result = ch_select_events(1, columns: %w[event_type platform])
    row = result.to_a.first

    assert_equal 'view', row['event_type']
    assert_equal 'ios', row['platform']
    assert_nil row['project_id'], 'Should only return requested columns'
  end

  # ---------------------------------------------------------------------------
  # Connection and feature flags
  # ---------------------------------------------------------------------------

  test "Clickhouse.with yields a working connection" do
    result = Clickhouse.with { |conn| conn.select_value("SELECT 1") }
    assert_equal 1, result
  end

  test "Clickhouse.build_connection creates a functional connection" do
    conn = Clickhouse.build_connection(database: 'default')
    assert_equal 1, conn.select_value("SELECT 1")
  end

  # Safe to mutate Rails.application.config: parallel workers are forked
  # processes (parallelize uses :processes by default), each with its own copy.
  # Would break if switched to `parallelize(with: :threads)`.
  test "feature flags read from Rails config" do
    original_write = Rails.application.config.clickhouse_write_enabled
    original_read = Rails.application.config.clickhouse_read_enabled

    Rails.application.config.clickhouse_write_enabled = true
    Rails.application.config.clickhouse_read_enabled = true
    assert Clickhouse.enabled?
    assert Clickhouse.read_enabled?

    Rails.application.config.clickhouse_write_enabled = false
    Rails.application.config.clickhouse_read_enabled = false
    assert_not Clickhouse.enabled?
    assert_not Clickhouse.read_enabled?
  ensure
    Rails.application.config.clickhouse_write_enabled = original_write
    Rails.application.config.clickhouse_read_enabled = original_read
  end

  # ---------------------------------------------------------------------------
  # Default values — verify UInt64 defaults don't mask missing data
  # ---------------------------------------------------------------------------

  test "optional UInt64 fields default to 0 not nil" do
    insert_ch_events({ project_id: 1, event_type: 'view', created_at: FIXED_TS })

    row = ch_select_events(1, columns: %w[device_id visitor_id link_id inviter_id campaign_id]).to_a.first

    assert_equal 0, row['device_id']
    assert_equal 0, row['visitor_id']
    assert_equal 0, row['link_id']
    assert_equal 0, row['inviter_id']
    assert_equal 0, row['campaign_id']
  end

  test "optional String fields default to empty string" do
    insert_ch_events({ project_id: 1, event_type: 'view', created_at: FIXED_TS })

    row = ch_select_events(1, columns: %w[platform app_version device_model os country]).to_a.first

    assert_equal '', row['platform']
    assert_equal '', row['app_version']
    assert_equal '', row['device_model']
    assert_equal '', row['os']
    assert_equal '', row['country']
  end

  test "Array columns default to empty array when omitted" do
    insert_ch_events({ project_id: 1, event_type: 'view', created_at: FIXED_TS })

    row = ch_select_events(1, columns: %w[tags link_tags]).to_a.first

    assert_equal [], row['tags'], 'tags should default to empty array'
    assert_equal [], row['link_tags'], 'link_tags should default to empty array'
  end

  private

  def validate_identifier!(name)
    raise ArgumentError, "Invalid identifier: #{name}" unless name.to_s.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/)
  end

  def describe_table(table_name)
    validate_identifier!(table_name)
    Clickhouse.with do |conn|
      conn.select_all("DESCRIBE TABLE `#{table_name}`").to_a.to_h { |row| [row['name'], row['type']] }
    end
  end

  def table_engine(table_name)
    validate_identifier!(table_name)
    Clickhouse.with do |conn|
      conn.select_value("SELECT engine FROM system.tables WHERE database = currentDatabase() AND name = '#{table_name}'")
    end
  end

  def partition_count(table_name)
    validate_identifier!(table_name)
    Clickhouse.with do |conn|
      conn.select_value("SELECT COUNT(DISTINCT partition) FROM system.parts WHERE database = currentDatabase() AND table = '#{table_name}' AND active = 1")
    end
  end

  def assert_column(columns, name, expected_type)
    actual = columns[name]
    assert actual, "Column '#{name}' not found in table"
    assert_equal expected_type, actual, "Column '#{name}' expected type '#{expected_type}' but got '#{actual}'"
  end
end
