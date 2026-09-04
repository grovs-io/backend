# frozen_string_literal: true

require 'test_helper'

class Analytics::OverviewKeyMetricsTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include ChQueryCounter

  fixtures :projects, :instances

  fixtures :devices, :visitors

  fixtures :daily_project_metrics, :purchase_events

  setup do
    skip_unless_clickhouse!
    @ch_auto_rebuild_breakdowns = true
    @project = projects(:one)
    @now = Time.current
  end

  teardown { Rails.cache.clear }

  test 'computes all dashboard counters from events' do
    seed_dashboard_events

    metrics = call_key_metrics[:metrics]

    assert_equal 2, metrics[:views]
    assert_equal 1, metrics[:link_views]
    assert_equal 1, metrics[:opens]
    assert_equal 2, metrics[:installs]
    assert_equal 1, metrics[:link_driven_installs]
    assert_equal 1, metrics[:organic_installs]
    assert_equal 0, metrics[:reinstalls]
    assert_equal 1, metrics[:app_opens]
    assert_equal 1, metrics[:referred_users]
  end

  test 'computes total, new and returning users from visitor history' do
    seed_dashboard_events

    metrics = call_key_metrics[:metrics]

    # v1 (link install), v2 (organic install), v3 (returning), v4 (referred, no install)
    assert_equal 4, metrics[:total_users]
    assert_equal 1, metrics[:returning_users], 'v3 has pre-range history'
    assert_equal 2, metrics[:new_users], 'first-time visitors with an install: v1, v2'
    assert_in_delta 0.25, metrics[:returning_rate]
  end

  test 'platform filter scopes counters and users' do
    seed_dashboard_events

    metrics = call_key_metrics(platform: 'android')[:metrics]

    assert_equal 1, metrics[:installs], 'only v2 installed on android'
    assert_equal 0, metrics[:link_driven_installs]
    assert_equal 1, metrics[:organic_installs]
    assert_equal 1, metrics[:total_users]
    assert_equal 1, metrics[:new_users]
    assert_equal 0, metrics[:returning_users]
  end

  test 'excludes other projects and out-of-range events' do
    seed_dashboard_events

    metrics = call_key_metrics(start_date: Date.current - 7, end_date: Date.current - 6)[:metrics]

    assert_equal 0, metrics[:installs]
    assert_equal 0, metrics[:total_users]
  end

  test 'platform filter scopes prior history per platform, unfiltered spans platforms' do
    prior = (@now - 60.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    in_range = (@now - 1.hour).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_events([
      { event_id: 'xp_prior', project_id: @project.id, event_type: Grovs::Events::APP_OPEN,
        visitor_id: 31_005, platform: 'android', created_at: prior },
      { event_id: 'xp_install', project_id: @project.id, event_type: Grovs::Events::INSTALL, link_id: 0,
        visitor_id: 31_005, platform: 'ios', created_at: in_range }
    ])

    unfiltered = call_key_metrics[:metrics]
    assert_equal 1, unfiltered[:returning_users], 'android history makes the visitor returning overall'
    assert_equal 0, unfiltered[:new_users]

    ios = call_key_metrics(platform: 'ios')[:metrics]
    assert_equal 1, ios[:total_users]
    assert_equal 0, ios[:returning_users], 'no prior iOS history — legacy classifies per platform'
    assert_equal 1, ios[:new_users], 'first iOS activity with an install must be new on iOS'

    assert_equal 0, call_key_metrics(platform: 'android')[:metrics][:total_users]
  end

  test 'reinstalls are counted separately, never inside installs' do
    in_range = (@now - 1.hour).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_events([
      { event_id: 'ri_install', project_id: @project.id, event_type: Grovs::Events::INSTALL, link_id: 0,
        visitor_id: 31_006, platform: 'ios', created_at: in_range },
      { event_id: 'ri_reinstall', project_id: @project.id, event_type: Grovs::Events::REINSTALL, link_id: 0,
        visitor_id: 31_007, platform: 'ios', created_at: in_range }
    ])

    metrics = call_key_metrics[:metrics]

    assert_equal 1, metrics[:installs], 'legacy PG folds reinstalls into installs; CH keeps them pure'
    assert_equal 1, metrics[:reinstalls]
    assert_equal 1, metrics[:organic_installs]
  end

  test 'visitor_id 0 rollup rows (pre-consolidation MV residue) never count as a user' do
    seed_dashboard_events
    Clickhouse.with do |conn|
      conn.insert('visitor_daily', [{
                    project_id: @project.id, visitor_id: 0, event_date: Date.current.to_s,
                    event_type: Grovs::Events::VIEW, platform: 'ios', cnt: 5,
                    total_engagement_time: 0, inviter_id_state: 0
                  }])
    end

    metrics = call_key_metrics[:metrics]

    assert_equal 4, metrics[:total_users], 'anonymous visitor_id 0 must not appear as a synthetic user'
  end

  test 'pipeline-written events surface in key metrics end-to-end' do
    original = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true
    job = BatchEventProcessorJob.new
    job.jid = "km-e2e-#{SecureRandom.hex(4)}"

    event_json = {
      type: Grovs::Events::INSTALL, project_id: @project.id, device_id: devices(:ios_device).id,
      data: nil, link_id: nil, engagement_time: nil, created_at: 1.hour.from_now.iso8601
    }.to_json
    job.send(:process_batch, [event_json])
    rebuild_breakdown_rollups_for([{ created_at: 1.hour.from_now }])

    metrics = call_key_metrics(start_date: Date.current, end_date: Date.current + 2)[:metrics]

    assert_equal 1, metrics[:installs], 'real pipeline events must be counted (event-type casing!)'
    assert_equal 1, metrics[:organic_installs]
    assert_equal 1, metrics[:total_users]
  ensure
    Rails.application.config.clickhouse_write_enabled = original
    if job
      REDIS.with do |conn|
        conn.del("events:processing:#{job.jid}", "events:heartbeat:#{job.jid}")
        keys = conn.keys("#{BatchEventProcessorJob::CH_BATCH_DONE_PREFIX}:*")
        conn.del(*keys) if keys.any?
      end
    end
  end

  test 'caches per platform value without collisions when a real store is active' do
    seed_dashboard_events

    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      first = call_key_metrics[:metrics]
      assert_equal 2, first[:installs]

      queries = count_ch_queries { assert_equal first, call_key_metrics[:metrics] }
      assert_equal 0, queries, 'identical call must be served from cache'

      assert_equal 1, call_key_metrics(platform: 'ios')[:metrics][:installs],
                   'platform-filtered call must not hit the unfiltered cache entry'
      assert_equal 0, call_key_metrics(platform: 'all')[:metrics][:installs],
                   "literal platform=all is a real (empty) platform value, not the unfiltered entry"
      assert_equal first, call_key_metrics[:metrics],
                   'unfiltered entry must survive the platform=all request'
    end
  end

  test 'rebuilt rollup data stays invisible until the cache TTL elapses (documented SLA)' do
    assert_operator Analytics::OverviewStatsService.cache_ttl, :<=, 5.minutes,
                    'cache TTL is a documented freshness SLA — do not raise it silently'
    in_range = (@now - 1.hour).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')

    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      insert_ch_events([{ event_id: 'sla_1', project_id: @project.id, event_type: Grovs::Events::INSTALL,
                          link_id: 0, visitor_id: 31_008, platform: 'ios', created_at: in_range }])
      assert_equal 1, call_key_metrics[:metrics][:installs]

      insert_ch_events([{ event_id: 'sla_2', project_id: @project.id, event_type: Grovs::Events::INSTALL,
                          link_id: 0, visitor_id: 31_009, platform: 'ios', created_at: in_range }])
      assert_equal 1, call_key_metrics[:metrics][:installs],
                   'rebuilt data must NOT appear while the cache entry is live'

      travel(Analytics::OverviewStatsService.cache_ttl + 1.second) do
        assert_equal 2, call_key_metrics[:metrics][:installs],
                     'rebuilt data must appear once the TTL elapses, without manual invalidation'
      end
    end
  end

  test 'includes revenue totals summed from daily project metrics across platforms' do
    DailyProjectMetric.create!(project_id: @project.id, event_date: Date.current, platform: 'ios',
                               revenue: 3000, units_sold: 3, cancellations: 1, first_time_purchases: 2)
    DailyProjectMetric.create!(project_id: @project.id, event_date: Date.current, platform: 'android',
                               revenue: 2000, units_sold: 1, cancellations: 0, first_time_purchases: 1)

    metrics = call_key_metrics[:metrics]

    assert_equal 5000, metrics[:revenue]
    assert_equal 4, metrics[:units_sold]
    assert_equal 1, metrics[:cancellations]
    assert_equal 3, metrics[:first_time_purchases]
  end

  test 'arpu divides revenue by total users; arppu by distinct paying devices' do
    seed_dashboard_events # 4 total users
    DailyProjectMetric.create!(project_id: @project.id, event_date: Date.current, platform: 'ios', revenue: 4000)
    dev_ios = devices(:ios_device).id
    dev_android = devices(:android_device).id
    [dev_ios, dev_ios, dev_android].each_with_index do |dev, i|
      PurchaseEvent.create!(project_id: @project.id, date: Time.current, event_type: Grovs::Purchases::EVENT_BUY,
                            device_id: dev, webhook_validated: true, transaction_id: "km_txn_#{i}")
    end

    metrics = call_key_metrics[:metrics]

    assert_equal 4000, metrics[:revenue]
    assert_in_delta 1000.0, metrics[:arpu], 0.001, '4000 / 4 users'
    assert_in_delta 2000.0, metrics[:arppu], 0.001, '4000 / 2 distinct paying devices'
  end

  test 'arppu paying-device count applies the purchase filters (event type, validation, device)' do
    DailyProjectMetric.create!(project_id: @project.id, event_date: Date.current, platform: 'ios', revenue: 6000)
    ios = devices(:ios_device).id
    android = devices(:android_device).id
    web = devices(:web_device).id
    base = { project_id: @project.id, date: Time.current }

    # Counted: buy (validated), refund_reversed (validated), buy (store=false so validation not required).
    PurchaseEvent.create!(**base, event_type: Grovs::Purchases::EVENT_BUY, device_id: ios,
                          webhook_validated: true, transaction_id: 'pf_buy')
    PurchaseEvent.create!(**base, event_type: Grovs::Purchases::EVENT_REFUND_REVERSED, device_id: android,
                          webhook_validated: true, transaction_id: 'pf_rr')
    PurchaseEvent.create!(**base, event_type: Grovs::Purchases::EVENT_BUY, device_id: web,
                          store: false, webhook_validated: false, transaction_id: 'pf_nonstore')
    # Excluded: refund event type; unvalidated store purchase; nil device.
    PurchaseEvent.create!(**base, event_type: Grovs::Purchases::EVENT_REFUND, device_id: ios,
                          webhook_validated: true, transaction_id: 'pf_refund')
    PurchaseEvent.create!(**base, event_type: Grovs::Purchases::EVENT_BUY, device_id: ios,
                          store: true, webhook_validated: false, transaction_id: 'pf_unvalidated')
    PurchaseEvent.create!(**base, event_type: Grovs::Purchases::EVENT_BUY, device_id: nil,
                          webhook_validated: true, transaction_id: 'pf_nodevice')

    # 3 distinct paying devices (ios, android, web) → 6000 / 3.
    assert_in_delta 2000.0, call_key_metrics[:metrics][:arppu], 0.001
  end

  test 'arppu paying-device count and revenue respect the platform filter' do
    DailyProjectMetric.create!(project_id: @project.id, event_date: Date.current, platform: 'ios', revenue: 3000)
    DailyProjectMetric.create!(project_id: @project.id, event_date: Date.current, platform: 'android', revenue: 999)
    base = { project_id: @project.id, date: Time.current, webhook_validated: true }
    PurchaseEvent.create!(**base, event_type: Grovs::Purchases::EVENT_BUY,
                          device_id: devices(:ios_device).id, transaction_id: 'pp_ios')
    PurchaseEvent.create!(**base, event_type: Grovs::Purchases::EVENT_BUY,
                          device_id: devices(:android_device).id, transaction_id: 'pp_android')

    metrics = call_key_metrics(platform: 'ios')[:metrics]

    assert_equal 3000, metrics[:revenue], 'android revenue excluded by platform filter'
    assert_in_delta 3000.0, metrics[:arppu], 0.001, '3000 / 1 ios paying device'
  end

  test 'revenue respects the platform filter' do
    DailyProjectMetric.create!(project_id: @project.id, event_date: Date.current, platform: 'ios',
                               revenue: 3000, units_sold: 2)
    DailyProjectMetric.create!(project_id: @project.id, event_date: Date.current, platform: 'android',
                               revenue: 500, units_sold: 5)

    ios = call_key_metrics(platform: 'ios')[:metrics]

    assert_equal 3000, ios[:revenue]
    assert_equal 2, ios[:units_sold]
  end

  test 'zero users or zero paying devices yields 0.0 arpu and arppu (no divide-by-zero)' do
    DailyProjectMetric.create!(project_id: @project.id, event_date: Date.current, platform: 'ios', revenue: 5000)

    metrics = call_key_metrics[:metrics]

    assert_equal 5000, metrics[:revenue]
    assert_equal 0.0, metrics[:arpu], 'no in-range visitors → arpu 0.0'
    assert_equal 0.0, metrics[:arppu], 'no paying devices → arppu 0.0'
  end

  test 'empty range returns zeroed metrics with 0.0 rate' do
    metrics = call_key_metrics[:metrics]

    metrics.each do |key, value|
      next if key == :returning_rate

      assert_equal 0, value, "#{key} must be 0"
    end
    assert_equal 0.0, metrics[:returning_rate]
  end

  private

  test 'a web platform filter counts desktop-family visitors, as PG does' do
    seed_dashboard_events
    in_range = (@now - 1.hour).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_events([
      { event_id: 'km_v7_mac', project_id: @project.id, event_type: Grovs::Events::INSTALL,
        visitor_id: 31_007, platform: 'mac', created_at: in_range },
      { event_id: 'km_v8_win', project_id: @project.id, event_type: Grovs::Events::INSTALL,
        visitor_id: 31_008, platform: 'windows', created_at: in_range }
    ])

    web = call_key_metrics(platform: 'web')[:metrics]

    assert_equal 2, web[:total_users], "raw platforms must normalize to web, as PG's platform_for_metrics does"
  end

  test 'user_trends web filter counts desktop-family visitors like the tile' do
    seed_dashboard_events
    in_range = (@now - 1.hour).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_events([
      { event_id: 'ut_v9_mac', project_id: @project.id, event_type: Grovs::Events::INSTALL,
        visitor_id: 31_009, platform: 'mac', created_at: in_range }
    ])

    points = Analytics::OverviewStatsService.user_trends(
      @project.id, start_date: Date.current - 1, end_date: Date.current, platform: 'web'
    )[:points]

    assert_equal 1, points.sum { |pt| pt[:new_users].to_i }, 'the mac install must match the web filter'
  end

  test 'a custom-event-only visitor is not a user' do
    seed_dashboard_events
    insert_ch_events([
      { event_id: 'km_v5_custom', project_id: @project.id, event_type: Grovs::Events::CUSTOM,
        visitor_id: 31_005, platform: 'ios', created_at: (@now - 1.hour).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }
    ])

    metrics = call_key_metrics[:metrics]

    assert_equal 4, metrics[:total_users], 'custom events do not create a billable user'
  end

  test 'the new-users chart classifies the same population as the tile' do
    seed_dashboard_events
    insert_ch_events([
      { event_id: 'km_v6_custom_prior', project_id: @project.id, event_type: Grovs::Events::CUSTOM,
        visitor_id: 31_006, platform: 'ios', created_at: (@now - 60.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') },
      { event_id: 'km_v6_install', project_id: @project.id, event_type: Grovs::Events::INSTALL,
        visitor_id: 31_006, platform: 'ios', created_at: (@now - 1.hour).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }
    ])

    tile = call_key_metrics[:metrics][:new_users]
    chart = Analytics::OverviewStatsService.user_trends(
      @project.id, start_date: Date.current - 1, end_date: Date.current
    )[:points].sum { |pt| pt[:new_users].to_i }

    assert_equal 3, tile, 'a pre-range custom event must not make v6 a returning user'
    assert_equal tile, chart, 'tile and chart must classify first_date over the same rows'
  end

  def call_key_metrics(start_date: Date.current - 1, end_date: Date.current, platform: nil)
    Analytics::OverviewStatsService.key_metrics(
      @project.id, start_date: start_date, end_date: end_date, platform: platform
    )
  end

  def seed_dashboard_events
    in_range = (@now - 1.hour).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    prior = (@now - 60.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')

    insert_ch_events([
      # v1: link-driven installer (new)
      { event_id: 'km_v1_view', project_id: @project.id, event_type: Grovs::Events::VIEW, link_id: 501,
        visitor_id: 31_001, platform: 'ios', created_at: in_range },
      { event_id: 'km_v1_install', project_id: @project.id, event_type: Grovs::Events::INSTALL, link_id: 501,
        visitor_id: 31_001, platform: 'ios', created_at: in_range },
      { event_id: 'km_v1_appopen', project_id: @project.id, event_type: Grovs::Events::APP_OPEN,
        visitor_id: 31_001, platform: 'ios', created_at: in_range },
      # v2: organic installer (new, android)
      { event_id: 'km_v2_view', project_id: @project.id, event_type: Grovs::Events::VIEW, link_id: 0,
        visitor_id: 31_002, platform: 'android', created_at: in_range },
      { event_id: 'km_v2_install', project_id: @project.id, event_type: Grovs::Events::INSTALL, link_id: 0,
        visitor_id: 31_002, platform: 'android', created_at: in_range },
      # v3: returning (prior history, only an OPEN in range)
      { event_id: 'km_v3_prior', project_id: @project.id, event_type: Grovs::Events::APP_OPEN,
        visitor_id: 31_003, platform: 'ios', created_at: prior },
      { event_id: 'km_v3_open', project_id: @project.id, event_type: Grovs::Events::OPEN, link_id: 502,
        visitor_id: 31_003, platform: 'ios', created_at: in_range },
      # v4: referred user event (new, no install)
      { event_id: 'km_v4_referred', project_id: @project.id, event_type: Grovs::Events::USER_REFERRED,
        visitor_id: 31_004, platform: 'ios', created_at: in_range },
      # decoy: other project
      { event_id: 'km_foreign', project_id: 99_999, event_type: Grovs::Events::INSTALL, link_id: 501,
        visitor_id: 31_001, platform: 'ios', created_at: in_range }
    ])
  end
end
