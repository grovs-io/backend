# frozen_string_literal: true

require 'test_helper'

class Analytics::OverviewStatsServiceTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances

  setup do
    skip_unless_clickhouse!
    @ch_auto_rebuild_breakdowns = true
    @original_read_enabled = Rails.application.config.clickhouse_read_enabled
    Rails.application.config.clickhouse_read_enabled = true
    @original_rollups_read_enabled = Rails.application.config.clickhouse_analytics_rollups_read_enabled
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = false
    @project = projects(:one)
    @now = Time.current
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read_enabled if defined?(@original_read_enabled)
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = @original_rollups_read_enabled if defined?(@original_rollups_read_enabled)
  end

  # --- versions ---

  test 'versions groups by platform with user counts' do
    insert_test_events_for_versions
    result = Analytics::OverviewStatsService.versions(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current
    )
    assert result[:platforms].is_a?(Hash)
    assert result[:platforms].any?

    # Test data: ios has 1.0.0 (1 user), android has 2.0.0 (1 user) — each sole version → 100%
    ios = result[:platforms]['ios']
    assert_equal 1, ios.size
    assert_equal '1.0.0', ios[0][:version]
    assert_equal 1, ios[0][:users]
    assert_equal 100.0, ios[0][:percent], 'Single version per platform → 100%'

    android = result[:platforms]['android']
    assert_equal 1, android.size
    assert_equal '2.0.0', android[0][:version]
    assert_equal 1, android[0][:users]
    assert_equal 100.0, android[0][:percent], 'Single version per platform → 100%'
  end

  test 'versions limits to top 10 per platform' do
    # Insert 12 versions for ios
    rows = 12.times.map do |i|
      {
        project_id: @project.id, event_type: 'VIEW', app_version: "1.#{i}.0",
        visitor_id: 3000 + i, platform: 'ios',
        created_at: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
      }
    end
    insert_ch_events(rows)

    result = Analytics::OverviewStatsService.versions(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current
    )
    assert result[:platforms]['ios'].size <= 10, 'Should limit to 10 per platform'
  end

  test 'versions uses raw events while analytics rollup reads are disabled' do
    insert_test_events_for_versions

    ClickhouseReadService.stub(:project_version_daily_stats, ->(*) { raise 'rollup should not be used' }) do
      result = Analytics::OverviewStatsService.versions(
        @project.id,
        start_date: 7.days.ago.to_date,
        end_date: Date.current
      )

      assert_equal '1.0.0', result[:platforms]['ios'][0][:version]
    end
  end

  test 'versions uses version rollup when analytics rollup reads are enabled' do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true

    fake_rows = [{ 'platform' => 'ios', 'version' => '9.9.9', 'users' => 7 }]
    ClickhouseReadService.stub(:project_version_daily_stats, ->(*) { fake_rows }) do
      result = Analytics::OverviewStatsService.versions(
        @project.id,
        start_date: 7.days.ago.to_date,
        end_date: Date.current
      )

      assert_equal [{ version: '9.9.9', users: 7, percent: 100.0 }], result[:platforms]['ios']
    end
  end

  test 'versions returns empty platforms instead of raising when ClickHouse read fails' do
    Clickhouse.stub(:with, -> { raise StandardError, 'clickhouse unavailable' }) do
      assert_equal(
        { platforms: {} },
        Analytics::OverviewStatsService.versions(@project.id, start_date: 7.days.ago.to_date, end_date: Date.current)
      )
    end
  end

  # --- sources_breakdown ---

  test 'sources_breakdown classifies by link properties and includes total' do
    insert_test_events_with_sources
    result = Analytics::OverviewStatsService.sources_breakdown(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current
    )
    source_map = result[:sources].to_h { |s| [s[:name], s[:value]] }
    assert_equal 1, source_map['Organic'], 'Organic: 1 visitor (2000, no link properties)'
    assert_equal 1, source_map['Campaigns'], 'Campaigns: 1 visitor (2001, campaign_id=42)'
    assert_equal 1, source_map['Links'], 'Links: 1 visitor (2002, link_id=55)'
    assert_equal 3, result[:total], 'Total should be 3 unique visitors'
    assert_equal result[:sources].sum { |s| s[:value] }, result[:total]
  end

  test 'sources_breakdown classifies referrals and api links separately' do
    insert_ch_events([
      { project_id: @project.id, event_type: 'VIEW', visitor_id: 2101, platform: 'ios',
        link_id: 10, campaign_id: 0, sdk_generated: 1, link_visitor_id: 99,
        created_at: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N') },
      { project_id: @project.id, event_type: 'VIEW', visitor_id: 2102, platform: 'ios',
        link_id: 11, campaign_id: 0, sdk_generated: 1, link_visitor_id: 0,
        created_at: (@now - 1.hour).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }
    ])

    result = Analytics::OverviewStatsService.sources_breakdown(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current
    )
    source_map = result[:sources].to_h { |source| [source[:name], source[:value]] }

    assert_equal 1, source_map['Referrals']
    assert_equal 1, source_map['API Links']
    assert_equal 2, result[:total]
  end

  test 'sources_breakdown uses raw events while analytics rollup reads are disabled' do
    insert_test_events_with_sources

    ClickhouseReadService.stub(:project_source_daily_stats, ->(*) { raise 'rollup should not be used' }) do
      result = Analytics::OverviewStatsService.sources_breakdown(
        @project.id,
        start_date: 7.days.ago.to_date,
        end_date: Date.current
      )

      assert_equal 3, result[:total]
    end
  end

  test 'sources_breakdown returns empty sources instead of raising when ClickHouse read fails' do
    Clickhouse.stub(:with, -> { raise StandardError, 'clickhouse unavailable' }) do
      assert_equal(
        { sources: [], total: 0 },
        Analytics::OverviewStatsService.sources_breakdown(
          @project.id,
          start_date: 7.days.ago.to_date,
          end_date: Date.current
        )
      )
    end
  end

  # --- user_trends ---

  test 'user_trends returns points with date, new_users, previous_new_users' do
    insert_test_events_for_versions
    result = Analytics::OverviewStatsService.user_trends(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current
    )
    assert result[:points].is_a?(Array)
    assert result[:points].any?, 'Expected at least one data point'

    point = result[:points].first
    assert point.key?(:date)
    assert point.key?(:new_users)
    assert point.key?(:previous_new_users)
  end

  test 'user_trends includes net daily revenue in usd cents honoring platform filter' do
    today = Date.current
    insert_ch_events([{
      project_id: @project.id, event_type: 'VIEW',
      visitor_id: 5100, platform: 'ios',
      created_at: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    }])
    DailyProjectMetric.create!(project_id: @project.id, event_date: today, platform: 'ios', revenue: 4299)
    DailyProjectMetric.create!(project_id: @project.id, event_date: today, platform: 'android', revenue: 100)

    point = Analytics::OverviewStatsService.user_trends(
      @project.id, start_date: today, end_date: today
    )[:points].first
    assert_equal 4399, point[:revenue_usd_cents], 'sums all platforms when no filter'
    assert point.key?(:previous_revenue_usd_cents)

    filtered = Analytics::OverviewStatsService.user_trends(
      @project.id, start_date: today, end_date: today, platform: 'ios'
    )[:points].first
    assert_equal 4299, filtered[:revenue_usd_cents], 'respects platform filter'
  end

  # Previous-period comparison must not read past the retention cutoff.
  test 'user_trends does not surface previous-period users older than the retention cutoff' do
    instances(:two).update!(cold_storage_days: 365, delete_days: 730) # free
    free_project = projects(:two)
    start_date = Date.current - 364 # previous period reaches into cold

    insert_ch_events([{
      project_id: free_project.id, event_type: 'VIEW', visitor_id: 7777, platform: 'ios',
      created_at: (Date.current - 500).to_time.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    }])

    points = Analytics::OverviewStatsService.user_trends(
      free_project.id, start_date: start_date, end_date: Date.current
    )[:points]

    assert_equal 0, points.sum { |p| p[:previous_new_users] },
                 'cold previous-period users must not leak past the retention cutoff'
  end

  # Fail closed: an unresolvable policy must clamp to today, not read unclamped.
  test 'user_trends fails closed when the retention policy cannot be resolved' do
    free_project = projects(:two)
    insert_ch_events([{
      project_id: free_project.id, event_type: 'VIEW', visitor_id: 8888, platform: 'ios',
      created_at: (Date.current - 40).to_time.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    }])

    Analytics::RetentionPolicy.stub(:cutoff_for, nil) do
      points = Analytics::OverviewStatsService.user_trends(
        free_project.id, start_date: Date.current - 30, end_date: Date.current
      )[:points]
      assert_equal 0, points.sum { |p| p[:previous_new_users] }, 'unresolved policy must fail closed'
    end
  end

  test 'user_trends revenue: multi-day, signed net, and previous-period alignment' do
    # Current period May 1-3 → previous period Apr 28-30 (offset-aligned day-for-day).
    sd = Date.new(2026, 5, 1)
    ed = Date.new(2026, 5, 3)

    # Current: May1 = 3000+2000 across platforms; May2 = net -200 (refund day); May3 = no rows.
    DailyProjectMetric.create!(project_id: @project.id, event_date: Date.new(2026, 5, 1), platform: 'ios', revenue: 3000)
    DailyProjectMetric.create!(project_id: @project.id, event_date: Date.new(2026, 5, 1), platform: 'android', revenue: 2000)
    DailyProjectMetric.create!(project_id: @project.id, event_date: Date.new(2026, 5, 2), platform: 'ios', revenue: -200)
    # Previous: Apr28 → aligns to May1; Apr29 → none (May2 prev = 0); Apr30 → aligns to May3.
    DailyProjectMetric.create!(project_id: @project.id, event_date: Date.new(2026, 4, 28), platform: 'ios', revenue: 1500)
    DailyProjectMetric.create!(project_id: @project.id, event_date: Date.new(2026, 4, 30), platform: 'ios', revenue: 999)

    points = Analytics::OverviewStatsService.user_trends(@project.id, start_date: sd, end_date: ed)[:points]

    assert_equal 3, points.size
    assert_equal 5000, points[0][:revenue_usd_cents], 'May1 sums platforms'
    assert_equal(-200, points[1][:revenue_usd_cents], 'May2 net negative from refund (signed)')
    assert_equal 0, points[2][:revenue_usd_cents], 'May3 no rows → 0'
    assert_equal 1500, points[0][:previous_revenue_usd_cents], 'May1 prev = Apr28'
    assert_equal 0, points[1][:previous_revenue_usd_cents], 'May2 prev = Apr29 (none)'
    assert_equal 999, points[2][:previous_revenue_usd_cents], 'May3 prev = Apr30'
  end

  test 'user_trends single-day range produces one point' do
    today = Date.current
    insert_ch_events([{
      project_id: @project.id, event_type: 'VIEW',
      visitor_id: 5000, platform: 'ios',
      created_at: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    }])

    result = Analytics::OverviewStatsService.user_trends(
      @project.id,
      start_date: today,
      end_date: today
    )
    assert_equal 1, result[:points].size
    assert_equal today.strftime('%Y-%m-%d'), result[:points].first[:date]
  end

  test 'user_trends returns empty points instead of raising when ClickHouse read fails' do
    Clickhouse.stub(:with, -> { raise StandardError, 'clickhouse unavailable' }) do
      assert_equal(
        { points: [] },
        Analytics::OverviewStatsService.user_trends(@project.id, start_date: 7.days.ago.to_date, end_date: Date.current)
      )
    end
  end

  # --- version_distribution ---

  test 'version_distribution returns entries with platforms hash and total' do
    insert_test_events_for_versions
    result = Analytics::OverviewStatsService.version_distribution(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current
    )
    assert result[:entries].is_a?(Array)
    assert result[:entries].any?, 'Expected at least one version entry'

    entry = result[:entries].first
    assert entry.key?(:version)
    assert entry.key?(:release_date)
    assert entry.key?(:platforms)
    assert entry.key?(:total)
    assert_kind_of Hash, entry[:platforms]
    assert_equal entry[:platforms].values.sum, entry[:total]
  end

  test 'version_distribution uses cached release date for known version' do
    with_memory_cache do
      cache_key = "analytics:release_date:ev:#{@project.id}:7.8.9"
      Rails.cache.write(cache_key, '2026-04-01')
      insert_ch_events([
        { project_id: @project.id, event_type: 'VIEW', platform: 'ios', app_version: '7.8.9',
          visitor_id: 901, created_at: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }
      ])

      result = Analytics::OverviewStatsService.version_distribution(
        @project.id,
        start_date: 7.days.ago.to_date,
        end_date: Date.current
      )
      entry = result[:entries].find { |row| row[:version] == '7.8.9' }

      assert_equal '2026-04-01', entry[:release_date]
    end
  end

  test 'version_distribution caches first seen release date on miss' do
    with_memory_cache do
      cache_key = "analytics:release_date:ev:#{@project.id}:8.0.0"
      insert_ch_events([
        { project_id: @project.id, event_type: 'VIEW', platform: 'ios', app_version: '8.0.0',
          visitor_id: 902, created_at: '2026-05-03 10:00:00.000' }
      ])

      Analytics::OverviewStatsService.version_distribution(
        @project.id,
        start_date: Date.new(2026, 5, 1),
        end_date: Date.new(2026, 5, 31)
      )

      assert_equal '2026-05-03', Rails.cache.read(cache_key)
    end
  end

  test 'version_distribution release date uses all history outside selected window' do
    with_memory_cache do
      insert_ch_events([
        { project_id: @project.id, event_type: 'VIEW', platform: 'ios', app_version: '9.0.0',
          visitor_id: 910, created_at: '2026-01-03 10:00:00.000' },
        { project_id: @project.id, event_type: 'VIEW', platform: 'ios', app_version: '9.0.0',
          visitor_id: 911, created_at: '2026-05-03 10:00:00.000' }
      ])

      result = Analytics::OverviewStatsService.version_distribution(
        @project.id,
        start_date: Date.new(2026, 5, 1),
        end_date: Date.new(2026, 5, 31)
      )
      entry = result[:entries].find { |row| row[:version] == '9.0.0' }

      assert_equal '2026-01-03', entry[:release_date]
    end
  end

  test 'version_distribution returns empty entries instead of raising when ClickHouse read fails' do
    Clickhouse.stub(:with, -> { raise StandardError, 'clickhouse unavailable' }) do
      assert_equal(
        { entries: [] },
        Analytics::OverviewStatsService.version_distribution(
          @project.id,
          start_date: 7.days.ago.to_date,
          end_date: Date.current
        )
      )
    end
  end

  # --- user_trends previous period alignment (T5) ---

  test 'user_trends previous period aligns day-for-day across month boundary' do
    # Current period: May 1-3 (3 days). Previous: Apr 28-30 (3 days).
    # duration = (May3 - May1) = 2, prev_sd = May1 - 2 - 1 = Apr28, prev_ed = Apr30
    #
    # Insert first-activity installs used by both the card and daily trend.
    events = []

    # Previous period: Apr28 = 2 visitors, Apr29 = 3 visitors, Apr30 = 1 visitor
    2.times { |i| events << event_row('2026-04-28 10:00:00.000', 8000 + i) }
    3.times { |i| events << event_row('2026-04-29 10:00:00.000', 8100 + i) }
    events << event_row('2026-04-30 10:00:00.000', 8200)

    # Current period: May1 = 4 visitors, May2 = 1 visitor, May3 = 2 visitors
    4.times { |i| events << event_row('2026-05-01 10:00:00.000', 8300 + i) }
    events << event_row('2026-05-02 10:00:00.000', 8400)
    2.times { |i| events << event_row('2026-05-03 10:00:00.000', 8500 + i) }

    insert_ch_events(events)

    result = Analytics::OverviewStatsService.user_trends(
      @project.id,
      start_date: '2026-05-01',
      end_date: '2026-05-03'
    )

    points = result[:points]
    assert_equal 3, points.size, 'Should have one point per day in current period'

    assert_equal '2026-05-01', points[0][:date]
    assert_equal '2026-05-02', points[1][:date]
    assert_equal '2026-05-03', points[2][:date]

    assert_equal 4, points[0][:new_users], 'May1 should have 4 install-qualified new users'
    assert_equal 1, points[1][:new_users], 'May2 should have 1 install-qualified new user'
    assert_equal 2, points[2][:new_users], 'May3 should have 2 install-qualified new users'

    # Day 0 of prev (Apr28) maps to day 0 of current (May1), etc.
    assert_equal 2, points[0][:previous_new_users], 'May1 previous should be Apr28 (2 new users)'
    assert_equal 3, points[1][:previous_new_users], 'May2 previous should be Apr29 (3 new users)'
    assert_equal 1, points[2][:previous_new_users], 'May3 previous should be Apr30 (1 new user)'
  end

  private

  def with_memory_cache
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = previous_cache
  end

  def event_row(created_at, visitor_id)
    {
      project_id: @project.id,
      event_type: 'install',
      visitor_id: visitor_id,
      platform: 'ios',
      created_at: created_at
    }
  end

  def insert_test_events_for_versions
    rows = [
      { project_id: @project.id, event_type: 'VIEW', app_version: '1.0.0',
        visitor_id: 1001, platform: 'ios',
        created_at: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N') },
      { project_id: @project.id, event_type: 'OPEN', app_version: '2.0.0',
        visitor_id: 1002, platform: 'android',
        created_at: (@now - 1.hour).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }
    ]
    insert_ch_events(rows)
  end

  def insert_test_events_with_sources
    rows = [
      # Organic (no link properties)
      { project_id: @project.id, event_type: 'VIEW', visitor_id: 2000,
        platform: 'ios', created_at: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N') },
      # Campaign
      { project_id: @project.id, event_type: 'VIEW', visitor_id: 2001,
        platform: 'ios', campaign_id: 42, link_id: 99,
        created_at: (@now - 1.hour).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') },
      # Link (no campaign, no sdk_generated)
      { project_id: @project.id, event_type: 'VIEW', visitor_id: 2002,
        platform: 'ios', link_id: 55,
        created_at: (@now - 2.hours).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }
    ]
    insert_ch_events(rows)
  end

  # This service once held private shadow copies of the flag readers, so primary? never reached it.
  test 'primary routes versions, version_distribution and sources_breakdown to the rollups' do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = false
    Rails.application.config.clickhouse_attribution_read_enabled = false
    Rails.application.config.clickhouse_primary = true
    args = { start_date: 7.days.ago.to_date, end_date: Date.current }

    assert_rollup_reader(:project_version_daily_stats) { Analytics::OverviewStatsService.versions(@project.id, **args) }
    assert_rollup_reader(:project_version_distribution_stats) do
      Analytics::OverviewStatsService.version_distribution(@project.id, **args)
    end
    assert_rollup_reader(:project_source_daily_stats) do
      Analytics::OverviewStatsService.sources_breakdown(@project.id, **args)
    end
  end

  test 'release dates cached from one source are not served to the other' do
    with_memory_cache do
      Rails.cache.write("analytics:release_date:ev:#{@project.id}:9.9.9", '2020-01-01')

      from_rollup = ClickhouseReadService.stub(:project_version_release_dates, [{ 'version' => '9.9.9', 'release_date' => '2026-06-06' }]) do
        Analytics::OverviewStatsService.send(:fetch_release_dates_from_rollup, @project.id, ['9.9.9'])
      end

      assert_equal '2026-06-06', from_rollup['9.9.9']
      assert_equal '2020-01-01', Rails.cache.read("analytics:release_date:ev:#{@project.id}:9.9.9")
    end
  end

  # These raw-CH surfaces have no PG equivalent, so a swallowed failure is a zeroed 200.
  test 'primary raises instead of serving an empty analytics payload' do
    Rails.application.config.clickhouse_primary = true
    args = { start_date: 7.days.ago.to_date, end_date: Date.current }

    Clickhouse.stub(:with, ->(*) { raise ClickHouse::Client::DatabaseError, 'Code: 210. DB::NetException: Connection refused. (NETWORK_ERROR)' }) do
      assert_raises(Clickhouse::Unavailable) { Analytics::OverviewStatsService.versions(@project.id, **args) }
      assert_raises(Clickhouse::Unavailable) { Analytics::OverviewStatsService.sources_breakdown(@project.id, **args) }
      assert_raises(Clickhouse::Unavailable) { Analytics::OverviewStatsService.key_metrics(@project.id, **args) }
    end
  end

  test 'without primary a failed read still serves the empty payload' do
    args = { start_date: 7.days.ago.to_date, end_date: Date.current }

    Clickhouse.stub(:with, ->(*) { raise ClickHouse::Client::DatabaseError, 'Code: 210. DB::NetException: Connection refused. (NETWORK_ERROR)' }) do
      assert_equal({ platforms: {} }, Analytics::OverviewStatsService.versions(@project.id, **args))
      assert_equal({ sources: [], total: 0 }, Analytics::OverviewStatsService.sources_breakdown(@project.id, **args))
    end
  end

  private

  def assert_rollup_reader(method, &block)
    called = false
    ClickhouseReadService.stub(method, lambda { |*_args, **_kwargs|
      called = true
      []
    }, &block)
    assert called, "expected #{method} to serve the rollup path under primary"
  end
end
