# frozen_string_literal: true

require "test_helper"

class ClickhouseReadServiceTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength -- read-query test catalog
  include ClickhouseTestHelper
  fixtures :instances, :projects, :visitors, :devices

  setup do
    skip_unless_clickhouse!
    @ch_auto_rebuild_breakdowns = true
    @project_id = 42
    @original_read_enabled = Rails.application.config.clickhouse_read_enabled
    Rails.application.config.clickhouse_read_enabled = true
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read_enabled if defined?(@original_read_enabled)
  end

  # =====================================================================
  # Helpers — insert raw events so MVs auto-populate
  # =====================================================================

  def ts(date_str, hour = 12)
    Time.utc(*date_str.split('-').map(&:to_i), hour, 0, 0).strftime('%Y-%m-%d %H:%M:%S.000')
  end

  def insert_event(attrs = {})
    defaults = {
      project_id: @project_id,
      event_type: 'view',
      device_id: 1,
      visitor_id: 1,
      link_id: 0,
      inviter_id: 0,
      campaign_id: 0,
      platform: 'ios',
      engagement_time: 0,
      country: '',
      created_at: ts('2026-05-01')
    }
    insert_ch_events(defaults.merge(attrs))
  end

  def insert_purchase(attrs = {})
    defaults = {
      project_id: @project_id,
      event_type: 'buy',
      purchase_type: 'subscription',
      product_id: 'com.test.premium',
      usd_price_cents: 999,
      currency: 'USD',
      quantity: 1,
      transaction_id: "txn_#{SecureRandom.hex(4)}",
      original_transaction_id: 'orig_001',
      store_source: 'apple',
      device_id: 1,
      link_id: 0,
      visitor_id: 1,
      purchase_date: ts('2026-05-01'),
      created_at: ts('2026-05-01')
    }
    Clickhouse.with { |conn| conn.insert('purchase_events', [defaults.merge(attrs)]) }
  end

  def billing_project_ids
    [projects(:one).id, projects(:one_test).id]
  end

  def create_pg_billing_stat(visitor, project_id:, event_date:, platform: 'ios')
    VisitorDailyStatistic.create!(
      visitor: visitor,
      project_id: project_id,
      event_date: event_date,
      platform: platform,
      views: 1
    )
  end

  def pg_billing_active_visitors(start_date:, end_date:)
    VisitorDailyStatistic
      .where(project_id: billing_project_ids, event_date: start_date..end_date)
      .select(:visitor_id)
      .distinct
      .count
  end

  # =====================================================================
  # 1. project_daily_stats — event aggregation by date/type/platform
  # =====================================================================

  test "project_daily_stats returns counts grouped by date, type, platform" do
    3.times { insert_event(event_type: 'view', platform: 'ios', created_at: ts('2026-05-01')) }
    2.times { insert_event(event_type: 'open', platform: 'ios', created_at: ts('2026-05-01')) }
    insert_event(event_type: 'view', platform: 'android', created_at: ts('2026-05-01'))
    insert_event(event_type: 'view', platform: 'ios', created_at: ts('2026-05-02'))

    rows = ClickhouseReadService.project_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-02'
    )

    ios_views_d1 = rows.find { |r| r['event_date'].to_s == '2026-05-01' && r['event_type'] == 'view' && r['platform'] == 'ios' }
    assert_equal 3, ios_views_d1['cnt']

    ios_opens_d1 = rows.find { |r| r['event_date'].to_s == '2026-05-01' && r['event_type'] == 'open' && r['platform'] == 'ios' }
    assert_equal 2, ios_opens_d1['cnt']

    android_views_d1 = rows.find { |r| r['event_date'].to_s == '2026-05-01' && r['event_type'] == 'view' && r['platform'] == 'android' }
    assert_equal 1, android_views_d1['cnt']

    ios_views_d2 = rows.find { |r| r['event_date'].to_s == '2026-05-02' && r['event_type'] == 'view' && r['platform'] == 'ios' }
    assert_equal 1, ios_views_d2['cnt']
  end

  test "project_daily_stats returns unique visitors via uniqMerge" do
    insert_event(event_type: 'view', visitor_id: 10, created_at: ts('2026-05-01'))
    insert_event(event_type: 'view', visitor_id: 20, created_at: ts('2026-05-01'))
    insert_event(event_type: 'view', visitor_id: 10, created_at: ts('2026-05-01')) # duplicate visitor

    rows = ClickhouseReadService.project_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    row = rows.find { |r| r['event_type'] == 'view' }
    assert_equal 3, row['cnt'], "Total count should be 3 (all events)"
    assert_equal 2, row['unique_visitors'], "Unique visitors should be 2 (deduplicated)"
  end

  test "project_daily_stats respects date range filter" do
    insert_event(event_type: 'view', created_at: ts('2026-04-30'))
    insert_event(event_type: 'view', created_at: ts('2026-05-01'))
    insert_event(event_type: 'view', created_at: ts('2026-05-03'))

    rows = ClickhouseReadService.project_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-02'
    )

    assert_equal 1, rows.size, "Only the May 1 event should be in range"
    assert_equal '2026-05-01', rows.first['event_date'].to_s
  end

  test "project_daily_stats returns engagement_time sum" do
    insert_event(event_type: 'open', engagement_time: 30, created_at: ts('2026-05-01'))
    insert_event(event_type: 'open', engagement_time: 45, created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.project_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    row = rows.find { |r| r['event_type'] == 'open' }
    assert_equal 75, row['total_engagement_time']
  end

  test "project_daily_stats returns empty result for project with no data" do
    rows = ClickhouseReadService.project_daily_stats(
      999999, start_date: '2026-05-01', end_date: '2026-05-31'
    )
    assert_equal 0, rows.size
  end

  test "project_daily_stats isolates projects" do
    insert_event(project_id: @project_id, event_type: 'view', created_at: ts('2026-05-01'))
    insert_event(project_id: 999, event_type: 'view', created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.project_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01'
    )
    assert_equal 1, rows.size
    assert_equal 1, rows.first['cnt']
  end

  # =====================================================================
  # 2. link_daily_stats — link-level event aggregation
  # =====================================================================

  test "link_daily_stats returns counts for a specific link" do
    insert_event(event_type: 'view', link_id: 100, created_at: ts('2026-05-01'))
    insert_event(event_type: 'view', link_id: 100, created_at: ts('2026-05-01'))
    insert_event(event_type: 'open', link_id: 100, created_at: ts('2026-05-01'))
    insert_event(event_type: 'view', link_id: 200, created_at: ts('2026-05-01')) # different link

    rows = ClickhouseReadService.link_daily_stats(
      @project_id, link_id: 100, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    views = rows.find { |r| r['event_type'] == 'view' }
    opens = rows.find { |r| r['event_type'] == 'open' }

    assert_equal 2, views['cnt']
    assert_equal 1, opens['cnt']
  end

  test "link_daily_stats excludes events with link_id 0" do
    insert_event(event_type: 'view', link_id: 0, created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.link_daily_stats(
      @project_id, link_id: 0, start_date: '2026-05-01', end_date: '2026-05-01'
    )
    # mv_link_daily has WHERE link_id != 0, so link_id=0 events never enter the MV
    assert_equal 0, rows.size
  end

  test "link_daily_stats returns empty for non-existent link" do
    insert_event(event_type: 'view', link_id: 100, created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.link_daily_stats(
      @project_id, link_id: 999, start_date: '2026-05-01', end_date: '2026-05-01'
    )
    assert_equal 0, rows.size
  end

  # =====================================================================
  # 3. top_links — ranked links by event count
  # =====================================================================

  test "top_links returns links ranked by count descending" do
    5.times { insert_event(event_type: 'view', link_id: 100, created_at: ts('2026-05-01')) }
    3.times { insert_event(event_type: 'view', link_id: 200, created_at: ts('2026-05-01')) }
    8.times { insert_event(event_type: 'view', link_id: 300, created_at: ts('2026-05-01')) }

    rows = ClickhouseReadService.top_links(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal 300, rows[0]['link_id']
    assert_equal 8, rows[0]['cnt']
    assert_equal 100, rows[1]['link_id']
    assert_equal 5, rows[1]['cnt']
    assert_equal 200, rows[2]['link_id']
    assert_equal 3, rows[2]['cnt']
  end

  test "top_links respects limit" do
    3.times { |i| insert_event(event_type: 'view', link_id: i + 1, created_at: ts('2026-05-01')) }

    rows = ClickhouseReadService.top_links(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01', limit: 2
    )
    assert_equal 2, rows.size
  end

  test "top_links filters by event_type" do
    3.times { insert_event(event_type: 'view', link_id: 100, created_at: ts('2026-05-01')) }
    5.times { insert_event(event_type: 'open', link_id: 100, created_at: ts('2026-05-01')) }

    views = ClickhouseReadService.top_links(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01', event_type: 'view'
    )
    assert_equal 1, views.size
    assert_equal 3, views.first['cnt']

    opens = ClickhouseReadService.top_links(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01', event_type: 'open'
    )
    assert_equal 5, opens.first['cnt']
  end

  # =====================================================================
  # 4. visitor_daily_stats — visitor-level aggregation
  # =====================================================================

  test "visitor_daily_stats returns counts for a specific visitor" do
    insert_event(event_type: 'view', visitor_id: 50, created_at: ts('2026-05-01'))
    insert_event(event_type: 'open', visitor_id: 50, created_at: ts('2026-05-01'))
    insert_event(event_type: 'view', visitor_id: 99, created_at: ts('2026-05-01')) # different visitor

    rows = ClickhouseReadService.visitor_daily_stats(
      @project_id, visitor_id: 50, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    views = rows.find { |r| r['event_type'] == 'view' }
    opens = rows.find { |r| r['event_type'] == 'open' }

    assert_equal 1, views['cnt']
    assert_equal 1, opens['cnt']
  end

  test "visitor_daily_stats returns empty for non-existent visitor" do
    rows = ClickhouseReadService.visitor_daily_stats(
      @project_id, visitor_id: 777, start_date: '2026-05-01', end_date: '2026-05-01'
    )
    assert_equal 0, rows.size
  end

  # =====================================================================
  # 5. purchase_project_daily_stats — revenue aggregation
  # =====================================================================

  test "purchase_project_daily_stats returns revenue by date and store" do
    insert_purchase(usd_price_cents: 999, store_source: 'apple', purchase_date: ts('2026-05-01'))
    insert_purchase(usd_price_cents: 499, store_source: 'google', purchase_date: ts('2026-05-01'))
    insert_purchase(usd_price_cents: 1500, store_source: 'apple', purchase_date: ts('2026-05-02'))

    rows = ClickhouseReadService.purchase_project_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-02'
    )

    apple_d1 = rows.find { |r| r['event_date'].to_s == '2026-05-01' && r['store_source'] == 'apple' }
    google_d1 = rows.find { |r| r['event_date'].to_s == '2026-05-01' && r['store_source'] == 'google' }
    apple_d2 = rows.find { |r| r['event_date'].to_s == '2026-05-02' && r['store_source'] == 'apple' }

    assert_equal 999, apple_d1['total_revenue_cents']
    assert_equal 1, apple_d1['units']
    assert_equal 499, google_d1['total_revenue_cents']
    assert_equal 1500, apple_d2['total_revenue_cents']
  end

  test "purchase_project_daily_stats includes paying_visitors via uniqMerge" do
    insert_purchase(visitor_id: 10, purchase_date: ts('2026-05-01'))
    insert_purchase(visitor_id: 20, purchase_date: ts('2026-05-01'))
    insert_purchase(visitor_id: 10, purchase_date: ts('2026-05-01')) # same visitor again

    rows = ClickhouseReadService.purchase_project_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    row = rows.first
    assert_equal 3, row['units'], "Total units should be 3"
    assert_equal 2, row['paying_visitors'], "Unique paying visitors should be 2"
  end

  test "purchase_project_daily_stats returns empty for project with no purchases" do
    rows = ClickhouseReadService.purchase_project_daily_stats(
      999999, start_date: '2026-05-01', end_date: '2026-05-31'
    )
    assert_equal 0, rows.size
  end

  test "purchase_project_daily_stats dedups a replayed purchase (same transaction_id)" do
    insert_purchase(transaction_id: 'txn_dup', usd_price_cents: 999, purchase_date: ts('2026-05-01'))
    insert_purchase(transaction_id: 'txn_dup', usd_price_cents: 999, purchase_date: ts('2026-05-01'))

    rows = ClickhouseReadService.purchase_project_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal 1, rows.size
    assert_equal 999, rows.first['total_revenue_cents'].to_i, "replayed purchase must count once, not double"
    assert_equal 1, rows.first['units'].to_i
  end

  test "purchase_project_daily_stats: newer version supersedes an earlier price (correction)" do
    insert_purchase(transaction_id: 'txn_corr', usd_price_cents: 999, purchase_date: ts('2026-05-01'), created_at: ts('2026-05-01'))
    insert_purchase(transaction_id: 'txn_corr', usd_price_cents: 1499, purchase_date: ts('2026-05-01'), created_at: ts('2026-05-02'))

    rows = ClickhouseReadService.purchase_project_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal 1, rows.size
    assert_equal 1499, rows.first['total_revenue_cents'].to_i, "FINAL must keep the latest version, not sum both"
  end

  # =====================================================================
  # 6. purchase_product_daily_stats — per-product revenue
  # =====================================================================

  test "purchase_product_daily_stats returns revenue for specific product" do
    insert_purchase(product_id: 'com.test.premium', usd_price_cents: 999, purchase_date: ts('2026-05-01'))
    insert_purchase(product_id: 'com.test.premium', usd_price_cents: 999, purchase_date: ts('2026-05-01'))
    insert_purchase(product_id: 'com.test.basic', usd_price_cents: 299, purchase_date: ts('2026-05-01'))

    rows = ClickhouseReadService.purchase_product_daily_stats(
      @project_id, product_id: 'com.test.premium', start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal 1, rows.size
    assert_equal 1998, rows.first['total_revenue_cents']
    assert_equal 2, rows.first['units']
  end

  test "purchase_product_daily_stats isolates products" do
    insert_purchase(product_id: 'com.test.premium', usd_price_cents: 999, purchase_date: ts('2026-05-01'))
    insert_purchase(product_id: 'com.test.basic', usd_price_cents: 299, purchase_date: ts('2026-05-01'))

    rows = ClickhouseReadService.purchase_product_daily_stats(
      @project_id, product_id: 'com.test.basic', start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal 299, rows.first['total_revenue_cents']
    assert_equal 1, rows.first['units']
  end

  # =====================================================================
  # 7. project_country_daily_stats — geo breakdown
  # =====================================================================

  test "project_country_daily_stats returns counts by country" do
    3.times { insert_event(event_type: 'view', country: 'US', created_at: ts('2026-05-01')) }
    2.times { insert_event(event_type: 'view', country: 'DE', created_at: ts('2026-05-01')) }
    insert_event(event_type: 'view', country: 'US', created_at: ts('2026-05-02'))

    rows = ClickhouseReadService.project_country_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-02'
    )

    us_d1 = rows.find { |r| r['event_date'].to_s == '2026-05-01' && r['country'] == 'US' && r['event_type'] == 'view' }
    de_d1 = rows.find { |r| r['event_date'].to_s == '2026-05-01' && r['country'] == 'DE' && r['event_type'] == 'view' }
    us_d2 = rows.find { |r| r['event_date'].to_s == '2026-05-02' && r['country'] == 'US' && r['event_type'] == 'view' }

    assert_equal 3, us_d1['cnt']
    assert_equal 2, de_d1['cnt']
    assert_equal 1, us_d2['cnt']
  end

  test "project_country_daily_stats includes unique_visitors per country" do
    insert_event(event_type: 'view', country: 'US', visitor_id: 10, created_at: ts('2026-05-01'))
    insert_event(event_type: 'view', country: 'US', visitor_id: 20, created_at: ts('2026-05-01'))
    insert_event(event_type: 'view', country: 'US', visitor_id: 10, created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.project_country_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    row = rows.find { |r| r['country'] == 'US' }
    assert_equal 3, row['cnt']
    assert_equal 2, row['unique_visitors']
  end

  test "project_country_daily_stats handles empty country string" do
    insert_event(event_type: 'view', country: '', created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.project_country_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal 1, rows.size
    assert_equal '', rows.first['country']
    assert_equal 1, rows.first['cnt']
  end

  # =====================================================================
  # 8. project_version_daily_stats — version distribution rollup
  # =====================================================================

  test "project_version_daily_stats returns top versions per platform with normalized unknown version" do
    insert_event(event_type: 'view', app_version: '', platform: 'ios', visitor_id: 10, created_at: ts('2026-05-01'))
    insert_event(event_type: 'open', app_version: '', platform: 'ios', visitor_id: 10, created_at: ts('2026-05-01'))
    insert_event(event_type: 'view', app_version: '2.0.0', platform: 'ios', visitor_id: 20, created_at: ts('2026-05-01'))
    insert_event(event_type: 'view', app_version: '3.0.0', platform: 'android', visitor_id: 30, created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.project_version_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    unknown = rows.find { |row| row['platform'] == 'ios' && row['version'] == 'Unknown' }
    android = rows.find { |row| row['platform'] == 'android' && row['version'] == '3.0.0' }

    assert_equal 1, unknown['users']
    assert_equal 2, unknown['cnt']
    assert_equal 1, android['users']
  end

  test "project_version_daily_stats applies platform filter and per-platform limit" do
    3.times do |i|
      insert_event(app_version: "ios-#{i}", platform: 'ios', visitor_id: 100 + i, created_at: ts('2026-05-01'))
      insert_event(app_version: "android-#{i}", platform: 'android', visitor_id: 200 + i, created_at: ts('2026-05-01'))
    end

    rows = ClickhouseReadService.project_version_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01', platform: 'ios', limit_per_platform: 2
    )

    assert_equal 2, rows.size
    assert rows.all? { |row| row['platform'] == 'ios' }
  end

  test "project_version_daily_stats web filter matches desktop-family raw platforms" do
    insert_event(app_version: '1.0.0', platform: 'mac', visitor_id: 100, created_at: ts('2026-05-01'))
    insert_event(app_version: '1.0.0', platform: 'windows', visitor_id: 101, created_at: ts('2026-05-01'))
    insert_event(app_version: '9.9.9', platform: 'ios', visitor_id: 102, created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.project_version_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01', platform: 'web'
    )

    assert_equal 2, rows.sum { |row| row['users'] }, 'mac and windows rows must match the web filter'
    assert rows.none? { |row| row['platform'] == 'ios' }
  end

  test "project_version_daily_stats treats blank platform as all platforms" do
    insert_event(app_version: '1.0.0', platform: 'ios', visitor_id: 100, created_at: ts('2026-05-01'))
    insert_event(app_version: '1.0.0', platform: 'android', visitor_id: 101, created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.project_version_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01', platform: ''
    )

    assert_equal %w[android ios], rows.map { |row| row['platform'] }.sort
  end

  test "project_version_release_dates scans all history from the rollup" do
    insert_event(app_version: '5.0.0', visitor_id: 10, created_at: ts('2026-01-10'))
    insert_event(app_version: '5.0.0', visitor_id: 11, created_at: ts('2026-05-10'))
    insert_event(app_version: '', visitor_id: 12, created_at: ts('2026-02-10'))

    rows = ClickhouseReadService.project_version_release_dates(@project_id, ['5.0.0', 'Unknown'])
    by_version = rows.to_h { |row| [row['version'], row['release_date'].to_s] }

    assert_equal '2026-01-10', by_version['5.0.0']
    assert_equal '2026-02-10', by_version['Unknown']
  end

  test "project_version_distribution_stats returns platform split for top overall versions" do
    insert_event(app_version: '1.0.0', platform: 'ios', visitor_id: 10, created_at: ts('2026-05-01'))
    insert_event(app_version: '1.0.0', platform: 'android', visitor_id: 11, created_at: ts('2026-05-01'))
    insert_event(app_version: '2.0.0', platform: 'ios', visitor_id: 12, created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.project_version_distribution_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01', limit: 1
    )

    assert_equal ['1.0.0'], rows.map { |row| row['version'] }.uniq
    assert_equal({ 'android' => 1, 'ios' => 1 }, rows.to_h { |row| [row['platform'], row['users']] })
  end

  # =====================================================================
  # 9. project_source_daily_stats — source classification rollup
  # =====================================================================

  test "project_source_daily_stats returns source visitor counts with existing precedence" do
    insert_event(visitor_id: 10, campaign_id: 1, link_id: 100, created_at: ts('2026-05-01'))
    insert_event(visitor_id: 11, sdk_generated: 1, link_visitor_id: 9, link_id: 101, created_at: ts('2026-05-01'))
    insert_event(visitor_id: 12, sdk_generated: 1, link_visitor_id: 0, link_id: 102, created_at: ts('2026-05-01'))
    insert_event(visitor_id: 13, link_id: 103, created_at: ts('2026-05-01'))
    insert_event(visitor_id: 14, created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.project_source_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01'
    )
    by_source = rows.to_h { |row| [row['source'], row['visitors']] }

    assert_equal 1, by_source['campaigns']
    assert_equal 1, by_source['referrals']
    assert_equal 1, by_source['api_links']
    assert_equal 1, by_source['links']
    assert_equal 1, by_source['organic']
  end

  test "project_source_daily_stats applies platform filter" do
    insert_event(visitor_id: 10, platform: 'ios', created_at: ts('2026-05-01'))
    insert_event(visitor_id: 11, platform: 'android', created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.project_source_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01', platform: 'android'
    )

    assert_equal 1, rows.size
    assert_equal 'organic', rows.first['source']
    assert_equal 1, rows.first['visitors']
  end

  test "project_source_daily_stats web filter matches desktop-family raw platforms" do
    insert_event(visitor_id: 10, platform: 'mac', created_at: ts('2026-05-01'))
    insert_event(visitor_id: 11, platform: 'ios', created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.project_source_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01', platform: 'web'
    )

    assert_equal 1, rows.size, 'only the mac visitor must match the web filter'
    assert_equal 1, rows.first['visitors']
  end

  test "project_source_daily_stats treats blank platform as all platforms" do
    insert_event(visitor_id: 10, platform: 'ios', created_at: ts('2026-05-01'))
    insert_event(visitor_id: 11, platform: 'android', created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.project_source_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01', platform: ''
    )

    assert_equal 2, rows.first['visitors']
  end

  # =====================================================================
  # 10. project_property_daily_stats — curated property rollup
  # =====================================================================

  test "project_property_daily_stats returns allowlisted property buckets only" do
    insert_event(visitor_id: 10, properties: { plan: 'pro', ignored: 'x' }, created_at: ts('2026-05-01'))
    insert_event(visitor_id: 10, properties: { plan: 'pro' }, created_at: ts('2026-05-01'))
    insert_event(visitor_id: 11, properties: { tier: 'gold' }, created_at: ts('2026-05-01'))
    insert_event(visitor_id: 12, properties: { ignored: 'y' }, created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.project_property_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    plan = rows.find { |row| row['property_key'] == 'plan' && row['property_value'] == 'pro' }
    tier = rows.find { |row| row['property_key'] == 'tier' && row['property_value'] == 'gold' }

    assert_equal 2, rows.size
    assert_equal 2, plan['cnt']
    assert_equal 1, plan['unique_visitors']
    assert_equal 1, tier['unique_visitors']
  end

  test "project_property_daily_stats applies property and platform filters" do
    insert_event(visitor_id: 10, platform: 'ios', properties: { plan: 'pro' }, created_at: ts('2026-05-01'))
    insert_event(visitor_id: 11, platform: 'android', properties: { plan: 'pro' }, created_at: ts('2026-05-01'))
    insert_event(visitor_id: 12, platform: 'android', properties: { tier: 'gold' }, created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.project_property_daily_stats(
      @project_id,
      start_date: '2026-05-01',
      end_date: '2026-05-01',
      property_key: 'plan',
      platform: 'android'
    )

    assert_equal 1, rows.size
    assert_equal 'plan', rows.first['property_key']
    assert_equal 'android', rows.first['platform']
    assert_equal 1, rows.first['unique_visitors']
  end

  test "project_property_daily_stats treats blank platform as all platforms" do
    insert_event(visitor_id: 10, platform: 'ios', properties: { plan: 'pro' }, created_at: ts('2026-05-01'))
    insert_event(visitor_id: 11, platform: 'android', properties: { plan: 'pro' }, created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.project_property_daily_stats(
      @project_id,
      start_date: '2026-05-01',
      end_date: '2026-05-01',
      property_key: 'plan',
      platform: ''
    )

    assert_equal %w[android ios], rows.map { |row| row['platform'] }.sort
  end

  # =====================================================================
  # 11. billing_active_visitors — exact future billing parity
  # =====================================================================

  test "billing_active_visitors exactly matches PG billing population" do
    production_id = projects(:one).id
    test_id = projects(:one_test).id
    ios_visitor = visitors(:ios_visitor)
    android_visitor = visitors(:android_visitor)

    create_pg_billing_stat(ios_visitor, project_id: production_id, event_date: Date.new(2026, 5, 1))
    create_pg_billing_stat(ios_visitor, project_id: test_id, event_date: Date.new(2026, 5, 2), platform: 'android')
    create_pg_billing_stat(android_visitor, project_id: production_id, event_date: Date.new(2026, 5, 31))

    insert_event(project_id: production_id, event_type: Grovs::Events::VIEW, visitor_id: ios_visitor.id, created_at: ts('2026-05-01'))
    insert_event(project_id: test_id, event_type: Grovs::Events::OPEN, visitor_id: ios_visitor.id, created_at: ts('2026-05-02'))
    insert_event(project_id: production_id, event_type: Grovs::Events::INSTALL, visitor_id: android_visitor.id, created_at: ts('2026-05-31'))
    insert_event(project_id: production_id, event_type: Grovs::Events::OPEN, visitor_id: android_visitor.id, created_at: ts('2026-05-31'))

    result = ClickhouseReadService.billing_active_visitors(
      billing_project_ids,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 31)
    )

    assert_equal pg_billing_active_visitors(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 31)), result
    assert_equal 2, result
  end

  test "billing_active_visitors excludes ClickHouse-only and anonymous events" do
    production_id = projects(:one).id
    ios_visitor = visitors(:ios_visitor)

    create_pg_billing_stat(ios_visitor, project_id: production_id, event_date: Date.new(2026, 6, 10))

    insert_event(project_id: production_id, event_type: Grovs::Events::APP_OPEN, visitor_id: ios_visitor.id, created_at: ts('2026-06-10'))
    insert_event(project_id: production_id, event_type: Grovs::Events::CUSTOM, visitor_id: 90_001, created_at: ts('2026-06-10'))
    insert_event(project_id: production_id, event_type: Grovs::Events::SCREEN_VIEW, visitor_id: 90_002, created_at: ts('2026-06-10'))
    insert_event(project_id: production_id, event_type: Grovs::Events::VIEW, visitor_id: 0, created_at: ts('2026-06-10'))

    result = ClickhouseReadService.billing_active_visitors(
      billing_project_ids,
      start_date: Date.new(2026, 6, 1),
      end_date: Date.new(2026, 6, 30)
    )

    assert_equal pg_billing_active_visitors(start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 30)), result
    assert_equal 1, result
  end

  test "billing_active_visitors preserves month-by-month billing semantics" do
    production_id = projects(:one).id
    ios_visitor = visitors(:ios_visitor)
    android_visitor = visitors(:android_visitor)

    create_pg_billing_stat(ios_visitor, project_id: production_id, event_date: Date.new(2026, 1, 15))
    create_pg_billing_stat(ios_visitor, project_id: production_id, event_date: Date.new(2026, 2, 15))
    create_pg_billing_stat(android_visitor, project_id: production_id, event_date: Date.new(2026, 2, 20))

    insert_event(project_id: production_id, event_type: Grovs::Events::OPEN, visitor_id: ios_visitor.id, created_at: ts('2026-01-15'))
    insert_event(project_id: production_id, event_type: Grovs::Events::OPEN, visitor_id: ios_visitor.id, created_at: ts('2026-02-15'))
    insert_event(project_id: production_id, event_type: Grovs::Events::VIEW, visitor_id: android_visitor.id, created_at: ts('2026-02-20'))

    clickhouse_total = [
      [Date.new(2026, 1, 1), Date.new(2026, 1, 31)],
      [Date.new(2026, 2, 1), Date.new(2026, 2, 28)]
    ].sum do |start_date, end_date|
      ClickhouseReadService.billing_active_visitors(
        billing_project_ids,
        start_date: start_date,
        end_date: end_date
      )
    end

    pg_total = [
      [Date.new(2026, 1, 1), Date.new(2026, 1, 31)],
      [Date.new(2026, 2, 1), Date.new(2026, 2, 28)]
    ].sum { |start_date, end_date| pg_billing_active_visitors(start_date: start_date, end_date: end_date) }

    assert_equal pg_total, clickhouse_total
    assert_equal 3, clickhouse_total
  end

  test "billing_active_visitors_per_month_total counts the same visitor once per active billing month" do
    production_id = projects(:one).id
    ios_visitor = visitors(:ios_visitor)
    android_visitor = visitors(:android_visitor)

    create_pg_billing_stat(ios_visitor, project_id: production_id, event_date: Date.new(2026, 1, 15))
    create_pg_billing_stat(ios_visitor, project_id: production_id, event_date: Date.new(2026, 2, 15))
    create_pg_billing_stat(android_visitor, project_id: production_id, event_date: Date.new(2026, 2, 20))

    insert_event(project_id: production_id, event_type: Grovs::Events::OPEN, visitor_id: ios_visitor.id, created_at: ts('2026-01-15'))
    insert_event(project_id: production_id, event_type: Grovs::Events::OPEN, visitor_id: ios_visitor.id, created_at: ts('2026-02-15'))
    insert_event(project_id: production_id, event_type: Grovs::Events::VIEW, visitor_id: android_visitor.id, created_at: ts('2026-02-20'))

    range_distinct = ClickhouseReadService.billing_active_visitors(
      billing_project_ids,
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 2, 28)
    )
    monthly_total = ClickhouseReadService.billing_active_visitors_per_month_total(
      billing_project_ids,
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 2, 28)
    )

    assert_equal 2, range_distinct
    assert_equal 3, monthly_total
  end

  test "billing_active_visitors returns zero when enabled and no matching rows exist" do
    assert_equal 0, ClickhouseReadService.billing_active_visitors(
      billing_project_ids,
      start_date: Date.new(2026, 7, 1),
      end_date: Date.new(2026, 7, 31)
    )
    assert_equal 0, ClickhouseReadService.billing_active_visitors(
      [],
      start_date: Date.new(2026, 7, 1),
      end_date: Date.new(2026, 7, 31)
    )
    assert_equal 0, ClickhouseReadService.billing_active_visitors_per_month_total(
      [],
      start_date: Date.new(2026, 7, 1),
      end_date: Date.new(2026, 7, 31)
    )
  end

  test "billing_active_visitors returns nil when ClickHouse reads are disabled" do
    Rails.application.config.clickhouse_read_enabled = false

    result = ClickhouseReadService.billing_active_visitors(
      billing_project_ids,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 31)
    )

    assert_nil result
  end

  # =====================================================================
  # 12. Clickhouse.read_enabled? flag behavior
  # =====================================================================

  test "Clickhouse.read_enabled? reflects config toggle" do
    original = Rails.application.config.clickhouse_read_enabled

    Rails.application.config.clickhouse_read_enabled = true
    assert Clickhouse.read_enabled?

    Rails.application.config.clickhouse_read_enabled = false
    assert_not Clickhouse.read_enabled?
  ensure
    Rails.application.config.clickhouse_read_enabled = original
  end

  test "Clickhouse.read_enabled? is independent of write flag" do
    original_read = Rails.application.config.clickhouse_read_enabled
    original_write = Rails.application.config.clickhouse_write_enabled

    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_write_enabled = false
    assert Clickhouse.read_enabled?
    assert_not Clickhouse.enabled?

    Rails.application.config.clickhouse_read_enabled = false
    Rails.application.config.clickhouse_write_enabled = true
    assert_not Clickhouse.read_enabled?
    assert Clickhouse.enabled?
  ensure
    Rails.application.config.clickhouse_read_enabled = original_read
    Rails.application.config.clickhouse_write_enabled = original_write
  end

  # =====================================================================
  # 13. Input sanitization
  # =====================================================================

  test "project_id must be integer" do
    assert_raises(ArgumentError) do
      ClickhouseReadService.project_daily_stats(
        "1; DROP TABLE events", start_date: '2026-05-01', end_date: '2026-05-01'
      )
    end
  end

  test "date params are validated" do
    assert_raises(Date::Error) do
      ClickhouseReadService.project_daily_stats(
        @project_id, start_date: "not-a-date", end_date: '2026-05-01'
      )
    end
  end

  test "link_id must be integer" do
    assert_raises(ArgumentError) do
      ClickhouseReadService.link_daily_stats(
        @project_id, link_id: "abc", start_date: '2026-05-01', end_date: '2026-05-01'
      )
    end
  end

  # =====================================================================
  # 14. Cross-table consistency — same events populate multiple MVs
  # =====================================================================

  test "single event populates project_daily, visitor_daily, and country_daily consistently" do
    insert_event(
      event_type: 'view', visitor_id: 42, country: 'JP', platform: 'ios',
      created_at: ts('2026-05-01')
    )

    project_rows = ClickhouseReadService.project_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01'
    )
    visitor_rows = ClickhouseReadService.visitor_daily_stats(
      @project_id, visitor_id: 42, start_date: '2026-05-01', end_date: '2026-05-01'
    )
    country_rows = ClickhouseReadService.project_country_daily_stats(
      @project_id, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal 1, project_rows.first['cnt']
    assert_equal 1, visitor_rows.first['cnt']
    assert_equal 1, country_rows.first['cnt']
    assert_equal 'JP', country_rows.first['country']
  end

  test "linked event populates link_daily MV" do
    insert_event(
      event_type: 'view', link_id: 555, campaign_id: 10,
      created_at: ts('2026-05-01')
    )

    link_rows = ClickhouseReadService.link_daily_stats(
      @project_id, link_id: 555, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal 1, link_rows.size
    assert_equal 1, link_rows.first['cnt']
  end

  test "event_filter_values returns sorted distinct platform/app_version/build, excluding empties and other projects" do
    insert_event(platform: 'ios', app_version: '1.2.0', build: '100', created_at: ts('2026-05-01'))
    insert_event(platform: 'android', app_version: '1.1.0', build: '99', created_at: ts('2026-05-02'))
    insert_event(platform: 'ios', app_version: '1.2.0', build: '100', created_at: ts('2026-05-03'))
    insert_event(platform: '', app_version: '', build: '', created_at: ts('2026-05-04'))
    insert_event(project_id: 999, platform: 'web', app_version: '9.9.9', build: '999', created_at: ts('2026-05-05'))

    result = ClickhouseReadService.event_filter_values(@project_id)

    assert_equal %w[android ios], result[:platforms]
    assert_equal %w[1.1.0 1.2.0], result[:app_versions]
    assert_equal %w[99 100].sort, result[:builds].sort
    assert_not_includes result[:platforms], 'web'
    assert_not_includes result[:platforms], ''
  end

  test "event_filter_values returns nil when reads are disabled (caller falls back to PG)" do
    Rails.application.config.clickhouse_read_enabled = false
    assert_nil ClickhouseReadService.event_filter_values(@project_id)
  end

  # --- event_overview_rows parity / robustness ---

  test "event_overview_rows returns nil when reads are disabled" do
    Rails.application.config.clickhouse_read_enabled = false
    assert_nil ClickhouseReadService.event_overview_rows([@project_id], start_date: '2026-05-01', end_date: '2026-05-02')
  end

  test "event_overview_rows treats the string 'false' as sdk_generated = 0" do
    insert_event(event_type: 'view', sdk_generated: 0, created_at: ts('2026-05-01'))
    insert_event(event_type: 'view', sdk_generated: 0, created_at: ts('2026-05-01'))
    insert_event(event_type: 'view', sdk_generated: 1, created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.event_overview_rows(
      [@project_id], start_date: '2026-05-01', end_date: '2026-05-01', sdk_generated: 'false'
    )

    assert_equal 2, rows.sum { |r| r['count'].to_i }, "'false' must exclude sdk_generated = 1 rows"
  end

  test "event_overview_rows: explicitly empty app_versions matches nothing (PG parity)" do
    insert_event(event_type: 'view', app_version: '1.0.0', created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.event_overview_rows(
      [@project_id], start_date: '2026-05-01', end_date: '2026-05-01', app_versions: []
    )

    assert_empty rows, "empty IN list must match nothing, like PG `where(app_version: [])`"
  end

  test "event_overview_rows: explicitly empty ads_platform filters for the empty value" do
    insert_event(event_type: 'view', ads_platform: '', created_at: ts('2026-05-01'))
    insert_event(event_type: 'view', ads_platform: 'google', created_at: ts('2026-05-01'))

    rows = ClickhouseReadService.event_overview_rows(
      [@project_id], start_date: '2026-05-01', end_date: '2026-05-01', ads_platform: ''
    )

    assert_equal 1, rows.sum { |r| r['count'].to_i }, "'' must filter for empty-value events only"
  end
end
