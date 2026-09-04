# frozen_string_literal: true

require 'test_helper'

class Analytics::UserProfileBackfillServiceTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :devices, :visitors

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
    @now = Time.current
    # The mandated ops order is sync-then-backfill; publish a generation so the guard passes.
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)
  end

  test 'reconstructs a user_profiles row per visitor from events' do
    seed_event(visitor_id: 1001, days_ago: 20, platform: 'ios', country: 'US')
    seed_event(visitor_id: 1001, days_ago: 10, platform: 'ios', country: 'US')
    seed_event(visitor_id: 1002, days_ago: 5,  platform: 'android', country: 'DE')

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    rows = profiles_final(@project.id).index_by { |r| r['visitor_id'].to_i }
    assert_equal [1001, 1002], rows.keys.sort

    assert_equal Date.parse((@now - 20.days).to_date.to_s), Date.parse(rows[1001]['first_seen'].to_s)
    assert_equal 'ios', rows[1001]['platform']
    assert_equal 'android', rows[1002]['platform']
  end

  test 'first_seen is the earliest event, last_seen the latest' do
    seed_event(visitor_id: 2001, days_ago: 30, platform: 'ios', country: 'US')
    seed_event(visitor_id: 2001, days_ago: 3,  platform: 'ios', country: 'US')

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    row = profiles_final(@project.id).first
    assert_equal Date.parse((@now - 30.days).to_date.to_s), Date.parse(row['first_seen'].to_s)
    assert_equal Date.parse((@now - 3.days).to_date.to_s),  Date.parse(row['last_seen'].to_s)
  end

  test 'skips visitorless events (visitor_id = 0)' do
    seed_event(visitor_id: 0, days_ago: 5, platform: 'web', country: 'US')

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    assert_equal 0, profiles_final(@project.id).length
  end

  # Covers the anti-join + future-event exclusion, not a live write racing the INSERT.
  test 'leaves a pre-existing profile untouched, even with a future-dated event' do
    insert_ch_user_profiles([{
      project_id: @project.id,
      visitor_id: 5001,
      first_seen: (@now - 2.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N'),
      last_seen: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'),
      platform: 'ios'
    }])
    seed_event(visitor_id: 5001, days_ago: 20, platform: 'android', country: 'DE')
    seed_event(visitor_id: 5001, days_ago: -30, platform: 'android', country: 'DE') # 30 days in the FUTURE

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    rows = profiles_final(@project.id)
    assert_equal 1, rows.length
    assert_equal 'ios', rows.first['platform'], 'live row must survive untouched'
    assert_in_delta @now.to_f, Time.zone.parse(rows.first['last_seen'].to_s).to_f, 120,
                    'live last_seen must stay ~now, not be pushed into the future'
  end

  test 'excludes future-dated events; first_seen/last_seen/dimensions come from real activity' do
    seed_event(visitor_id: 5500, days_ago: 5,   platform: 'ios',     country: 'US') # real, latest real
    seed_event(visitor_id: 5500, days_ago: 20,  platform: 'ios',     country: 'US') # real, earliest
    seed_event(visitor_id: 5500, days_ago: -30, platform: 'android', country: 'DE') # future -> ignored

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    row = profiles_final(@project.id).first
    assert_equal Date.parse((@now - 20.days).to_date.to_s), Date.parse(row['first_seen'].to_s)
    assert_equal Date.parse((@now - 5.days).to_date.to_s),  Date.parse(row['last_seen'].to_s)
    assert_equal 'ios', row['platform'], 'dimensions must ignore the future event'
    assert_equal 'US', row['country']
  end

  test 'a visitor with only future-dated events gets no profile' do
    seed_event(visitor_id: 5510, days_ago: -30, platform: 'ios', country: 'US') # only future

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    assert_not profiles_final(@project.id).any? { |r| r['visitor_id'].to_i == 5510 }
  end

  test 'is additive: only visitors without a profile are backfilled' do
    # 5600 already has a (live) profile; 5601 does not.
    insert_ch_user_profiles([{
      project_id: @project.id, visitor_id: 5600,
      first_seen: (@now - 2.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N'),
      last_seen: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'), platform: 'ios'
    }])
    seed_event(visitor_id: 5600, days_ago: 10, platform: 'android', country: 'DE')
    seed_event(visitor_id: 5601, days_ago: 10, platform: 'android', country: 'DE')

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    by_visitor = profiles_final(@project.id).index_by { |r| r['visitor_id'].to_i }
    assert_equal 'ios', by_visitor[5600]['platform'], 'existing profile left untouched'
    assert by_visitor.key?(5601), 'missing visitor backfilled'
    assert_equal 'android', by_visitor[5601]['platform']
  end

  test 'dimensions reflect the latest event (argMax), matching the live snapshot' do
    seed_event(visitor_id: 5700, days_ago: 20, platform: 'ios', country: 'US')
    seed_event(visitor_id: 5700, days_ago: 2,  platform: 'ios', country: 'DE') # latest

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    assert_equal 'DE', profiles_final(@project.id).first['country']
  end

  test 'retention cohorts appear after backfill (the bug this fixes)' do
    # Before: events exist but no profiles -> retention is empty.
    seed_event(visitor_id: 6001, days_ago: 10, platform: 'ios', country: 'US')
    insert_ch_visitor_daily([{
      project_id: @project.id,
      visitor_id: 6001,
      event_date: (@now - 8.days).to_date.to_s, # returned on day 2 -> retained at day 1
      event_type: 'OPEN',
      platform: 'ios',
      cnt: 1,
      total_engagement_time: 1000,
      inviter_id_state: 0
    }])

    before = Analytics::RetentionService.summary(@project.id)
    assert_equal [], before[:sparkline], 'precondition: no profiles -> no cohorts'

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    after = Analytics::RetentionService.summary(@project.id)
    assert_not_empty after[:sparkline], 'backfill should surface the cohort'
    assert_equal 100.0, after[:day_1]
  end

  test 'normalizes non-mobile platforms to web (matches live platform_for_metrics)' do
    # events hold the raw platform; live writes platform_for_metrics (non-mobile -> web).
    seed_event(visitor_id: 8001, days_ago: 5, platform: 'desktop', country: 'US')
    seed_event(visitor_id: 8002, days_ago: 5, platform: 'mac', country: 'US')
    seed_event(visitor_id: 8003, days_ago: 5, platform: 'windows', country: 'US')
    seed_event(visitor_id: 8004, days_ago: 5, platform: '', country: 'US')
    seed_event(visitor_id: 8005, days_ago: 5, platform: 'ios', country: 'US')
    seed_event(visitor_id: 8006, days_ago: 5, platform: 'android', country: 'US')

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    by_visitor = profiles_final(@project.id).index_by { |r| r['visitor_id'].to_i }
    assert_equal 'web', by_visitor[8001]['platform']
    assert_equal 'web', by_visitor[8002]['platform']
    assert_equal 'web', by_visitor[8003]['platform']
    assert_equal 'web', by_visitor[8004]['platform']
    assert_equal 'ios', by_visitor[8005]['platform']
    assert_equal 'android', by_visitor[8006]['platform']
  end

  test 'inserts only missing visitors, leaving an existing profile untouched' do
    insert_ch_user_profiles([{
      project_id: @project.id, visitor_id: 7000,
      first_seen: (@now - 2.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N'),
      last_seen: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'), platform: 'ios'
    }])
    seed_event(visitor_id: 7000, days_ago: 5, platform: 'android', country: 'DE') # already has a profile
    seed_event(visitor_id: 7001, days_ago: 5, platform: 'ios', country: 'US')     # new
    seed_event(visitor_id: 7002, days_ago: 5, platform: 'ios', country: 'US')     # new

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    by_visitor = profiles_final(@project.id).index_by { |r| r['visitor_id'].to_i }
    assert_equal [7000, 7001, 7002], by_visitor.keys.sort
    assert_equal 'ios', by_visitor[7000]['platform'], 'existing live profile left untouched'
  end

  test 'sharded backfill covers every visitor exactly once' do
    # 6 visitors spread across residues so shards partition them.
    (7200..7205).each { |vid| seed_event(visitor_id: vid, days_ago: 5, platform: 'ios', country: 'US') }

    Analytics::UserProfileBackfillService.backfill_project(@project.id, shards: 3)

    ids = profiles_final(@project.id).map { |r| r['visitor_id'].to_i }
    assert_equal (7200..7205).to_a, ids.sort
    assert_equal ids.uniq, ids, 'no visitor backfilled twice across shards'
  end

  test 'shards must be >= 1' do
    assert_raises(ArgumentError) { Analytics::UserProfileBackfillService.backfill_project(@project.id, shards: 0) }
  end

  test 'auto_shards sizes from the visitor count and per-shard target' do
    (7300..7305).each { |vid| seed_event(visitor_id: vid, days_ago: 5, platform: 'ios', country: 'US') } # 6 visitors

    with_env('CLICKHOUSE_BACKFILL_VISITORS_PER_SHARD', '2') do
      assert_equal 3, Analytics::UserProfileBackfillService.auto_shards(@project.id) # ceil(6/2)
    end
    with_env('CLICKHOUSE_BACKFILL_VISITORS_PER_SHARD', '1000') do
      assert_equal 1, Analytics::UserProfileBackfillService.auto_shards(@project.id) # ceil(6/1000) -> 1
    end
  end

  test 'shards: :auto backfills every visitor across the sized shards' do
    (7400..7405).each { |vid| seed_event(visitor_id: vid, days_ago: 5, platform: 'ios', country: 'US') }

    with_env('CLICKHOUSE_BACKFILL_VISITORS_PER_SHARD', '2') do # forces ceil(6/2)=3 shards
      Analytics::UserProfileBackfillService.backfill_project(@project.id, shards: :auto)
    end

    ids = profiles_final(@project.id).map { |r| r['visitor_id'].to_i }
    assert_equal (7400..7405).to_a, ids.sort
  end

  test 'inviter_id reflects the latest event (matches live current value), not the max historical id' do
    # Event with a larger historical inviter first, then a later correction to a smaller id.
    insert_ch_events([
      { project_id: @project.id, visitor_id: 7100, event_type: 'APP_OPEN', platform: 'ios',
        country: 'US', inviter_id: 999, created_at: (@now - 10.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') },
      { project_id: @project.id, visitor_id: 7100, event_type: 'APP_OPEN', platform: 'ios',
        country: 'US', inviter_id: 42, created_at: (@now - 2.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }
    ])

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    assert_equal 42, profiles_final(@project.id).first['inviter_id'].to_i,
                 'argMax by time must pick the latest inviter (42), not max(999)'
  end

  test 'attribute selection is deterministic on same-timestamp events (event_id tiebreak)' do
    # Same-ms events: argMax over (created_at, event_id) deterministically picks evt-b.
    ts = (@now - 5.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_events([
      { project_id: @project.id, visitor_id: 9001, event_type: 'APP_OPEN',
        platform: 'ios', country: 'US', created_at: ts, event_id: 'evt-a' },
      { project_id: @project.id, visitor_id: 9001, event_type: 'APP_OPEN',
        platform: 'ios', country: 'DE', created_at: ts, event_id: 'evt-b' }
    ])

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    row = profiles_final(@project.id).first
    assert_equal 'DE', row['country'], 'latest (created_at, event_id) is evt-b -> DE'
  end

  test 'sdk_identifier and uuid come from the synced PG identities, not from events' do
    v = visitors(:ios_visitor)
    seed_event(visitor_id: v.id, days_ago: 10, platform: 'ios', country: 'US')
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    row = profiles_final(@project.id).find { |r| r['visitor_id'].to_i == v.id }
    assert_equal 'user_ios_abc123', row['sdk_identifier']
    assert_equal v.uuid, row['uuid']
  end

  test 'a visitor with no synced identity backfills with blank identity, not a dropped row' do
    seed_event(visitor_id: 4242, days_ago: 10, platform: 'ios', country: 'US')

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    row = profiles_final(@project.id).find { |r| r['visitor_id'].to_i == 4242 }
    assert_not_nil row, 'LEFT JOIN must not drop visitors missing an identity row'
    assert_equal '', row['sdk_identifier']
    assert_equal '', row['uuid']
  end

  test 'falls back to the events sdk_identifier when no identity has been synced' do
    insert_ch_events([{ project_id: @project.id, visitor_id: 4300, event_type: 'APP_OPEN',
                        platform: 'ios', country: 'US', sdk_identifier: 'live_written',
                        created_at: (@now - 10.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }])

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    row = profiles_final(@project.id).find { |r| r['visitor_id'].to_i == 4300 }
    assert_equal 'live_written', row['sdk_identifier'],
                 'CH-native tenants must not regress to blank when the sync step has not run'
  end

  # Cutover prep runs writes + backfill BEFORE read routing; the guard must not depend on reads.
  test 'backfills with ClickHouse reads disabled, as the cutover runbook does' do
    original = Rails.application.config.clickhouse_read_enabled
    Rails.application.config.clickhouse_read_enabled = false
    seed_event(visitor_id: 3300, days_ago: 5, platform: 'ios', country: 'US')

    assert_nothing_raised { Analytics::UserProfileBackfillService.backfill_project(@project.id) }
    assert_equal 1, profiles_final(@project.id).length
  ensure
    Rails.application.config.clickhouse_read_enabled = original
  end

  # The window between migrate and the first sync is real; the backfill must refuse in it.
  test 'refuses to run before identities are synced, rather than burning in blank ones' do
    Clickhouse.with { |c| c.execute('TRUNCATE TABLE visitor_identities') }
    seed_event(visitor_id: 3100, days_ago: 5, platform: 'ios', country: 'US')

    err = assert_raises(Analytics::UserProfileBackfillService::MissingIdentitiesError) do
      Analytics::UserProfileBackfillService.backfill_project(@project.id)
    end
    assert_match(/sync_visitor_identities/, err.message)
    assert_empty profiles_final(@project.id), 'nothing may be written when the guard trips'
  end

  test 'the override lets an operator proceed without identities deliberately' do
    Clickhouse.with { |c| c.execute('TRUNCATE TABLE visitor_identities') }
    seed_event(visitor_id: 3200, days_ago: 5, platform: 'ios', country: 'US')

    with_env('ALLOW_MISSING_VISITOR_IDENTITIES', '1') do
      Analytics::UserProfileBackfillService.backfill_project(@project.id)
    end

    assert_equal 1, profiles_final(@project.id).length
  end

  # An intentionally cleared identifier is a value, not a gap — it must not resurrect the old one.
  test 'a cleared PG identifier stays cleared instead of falling back to the events value' do
    v = visitors(:ios_visitor)
    insert_ch_events([{ project_id: @project.id, visitor_id: v.id, event_type: 'APP_OPEN',
                        platform: 'ios', country: 'US', sdk_identifier: 'old_value',
                        created_at: (@now - 10.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }])
    v.update!(sdk_identifier: nil)
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    row = profiles_final(@project.id).find { |r| r['visitor_id'].to_i == v.id }
    assert_equal '', row['sdk_identifier'], 'a synced-but-empty identity must win over the stale event value'
  end

  test 'identity is not sourced from a stale events column' do
    v = visitors(:android_visitor)
    insert_ch_events([{ project_id: @project.id, visitor_id: v.id, event_type: 'APP_OPEN',
                        platform: 'android', country: 'US', sdk_identifier: 'stale_from_event',
                        created_at: (@now - 10.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }])
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)

    Analytics::UserProfileBackfillService.backfill_project(@project.id)

    row = profiles_final(@project.id).find { |r| r['visitor_id'].to_i == v.id }
    assert_equal 'user_android_xyz789', row['sdk_identifier'], 'PG identity must win over the event column'
  end

  test 'backfilled first_seen survives a ReplacingMergeTree merge (no live row)' do
    # No live row: the reconstructed cohort date must survive a forced merge.
    seed_event(visitor_id: 9100, days_ago: 25, platform: 'ios', country: 'US')
    seed_event(visitor_id: 9100, days_ago: 2,  platform: 'ios', country: 'US')

    Analytics::UserProfileBackfillService.backfill_project(@project.id)
    Clickhouse.with { |conn| conn.execute('OPTIMIZE TABLE user_profiles FINAL') }

    row = profiles_final(@project.id).first
    assert_equal Date.parse((@now - 25.days).to_date.to_s), Date.parse(row['first_seen'].to_s)
  end

  private

  def with_env(key, value)
    prev = ENV[key]
    ENV[key] = value
    yield
  ensure
    prev.nil? ? ENV.delete(key) : ENV[key] = prev
  end

  def seed_event(visitor_id:, days_ago:, platform:, country:)
    insert_ch_events({
      project_id: @project.id,
      visitor_id: visitor_id,
      event_type: 'APP_OPEN',
      platform: platform,
      country: country,
      created_at: (@now - days_ago.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    })
  end

  def profiles_final(project_id)
    Clickhouse.with do |conn|
      conn.select_all(
        "SELECT * FROM user_profiles FINAL WHERE project_id = #{Integer(project_id)} ORDER BY visitor_id"
      )
    end
  end
end
