# frozen_string_literal: true

require 'test_helper'
require 'support/clickhouse_test_helper'

class SessionBuildJobStitchingTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects

  WEB_VISITOR = 4001
  APP_VISITOR = 4002
  LATER_VISITOR = 4003

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @job = SessionBuildJob.new
    @job.defer_open_sessions = false
    @now = Time.current
  end

  test 'browser click and the install it caused become one session' do
    seed_journey(install_offset: 5.minutes)
    merge(WEB_VISITOR, APP_VISITOR)

    @job.send(:build_sessions_for_project, @project.id)

    rows = ch_query('session_events', @project.id)
    assert_equal 3, rows.size
    assert_equal ['sdk_abc'], rows.map { |r| r['session_id'] }.uniq
    assert_equal [APP_VISITOR], rows.map { |r| r['visitor_id'].to_i }.uniq
  end

  test 'stitched session takes attribution from the click and device from the app' do
    seed_journey(install_offset: 5.minutes)
    merge(WEB_VISITOR, APP_VISITOR)

    @job.send(:build_sessions_for_project, @project.id)

    summaries = ch_query('session_summary', @project.id)
    assert_equal 1, summaries.size
    assert_equal 77, summaries.first['link_id'].to_i, 'attribution must come from the click'
    assert_equal 'ios', summaries.first['platform'], 'device must come from the app'
    assert_equal '2.0', summaries.first['app_version']
  end

  test 'a click beyond the inactivity gap stays its own session' do
    seed_journey(install_offset: 31.minutes)
    merge(WEB_VISITOR, APP_VISITOR)

    @job.send(:build_sessions_for_project, @project.id)

    rows = ch_query('session_events', @project.id)
    assert_equal 2, rows.map { |r| r['session_id'] }.uniq.size
    click = rows.find { |r| r['event_type'] == 'VIEW' }
    assert_equal "synth_#{APP_VISITOR}_0", click['session_id']
  end

  test 'a merge recorded after sessionization does not duplicate the click' do
    seed_journey(install_offset: 5.minutes)

    @job.send(:build_sessions_for_project, @project.id)
    before = ch_query('session_events', @project.id).size

    merge(WEB_VISITOR, APP_VISITOR)
    @job.send(:build_sessions_for_project, @project.id)

    assert_equal before, ch_query('session_events', @project.id).size
  end

  test 'without a merge the click and the install stay separate visitors' do
    seed_journey(install_offset: 5.minutes)

    @job.send(:build_sessions_for_project, @project.id)

    rows = ch_query('session_events', @project.id)
    assert_equal [WEB_VISITOR, APP_VISITOR].sort, rows.map { |r| r['visitor_id'].to_i }.uniq.sort
    assert_equal 2, rows.map { |r| r['session_id'] }.uniq.size
  end

  test 'a batch ending on a blank-session event still writes those rows' do
    base = @now - 3.hours
    insert_ch_events([
      event(visitor_id: APP_VISITOR, at: base, session_id: 'sdk_abc'),
      event(visitor_id: APP_VISITOR, at: base + 2.minutes, session_id: '')
    ])

    @job.send(:build_sessions_for_project, @project.id)

    assert_equal 2, ch_query('session_events', @project.id).size,
                 'the tail flush must emit rows still buffered when paging stops'
  end

  test 'a buffer spanning two pages is not split' do
    base = @now - 3.hours
    page_one = [ch_row(APP_VISITOR, base, '')]
    page_two = [ch_row(APP_VISITOR, base + 2.minutes, 'sdk_abc')]

    rows_one, _, state = @job.send(:sessionize_events, page_one, @project.id, {})
    rows_two, = @job.send(:sessionize_events, page_two, @project.id, state)

    assert_empty rows_one, 'the blank-session event must stay buffered across the page boundary'
    assert_equal ['sdk_abc'], rows_two.map { |r| r[:session_id] }.uniq
  end

  test 'perform defers a fresh click and sessionizes a settled one' do
    stub_ch_flags(true)
    insert_ch_events([event(visitor_id: WEB_VISITOR, at: @now - 1.minute, session_id: '')])
    SessionBuildJob.new.perform(lookback_days: 1)
    assert_equal 0, ch_query('session_events', @project.id).size

    insert_ch_events([event(visitor_id: APP_VISITOR, at: @now - 3.hours, session_id: '')])
    SessionBuildJob.new.perform(lookback_days: 1)
    assert_equal [APP_VISITOR], ch_query('session_events', @project.id).map { |r| r['visitor_id'].to_i }.uniq
  ensure
    unstub_ch_flags
    REDIS.with { |c| c.del('sidekiq:single_flight:session_build') }
  end

  test 'a visitor emitting blank-session events without pause is still sessionized' do
    rows = (1..20).map { |i| event(visitor_id: WEB_VISITOR, at: @now - (i * 5).minutes, session_id: "") }
    insert_ch_events(rows)
    @job.defer_open_sessions = true

    assert_equal [WEB_VISITOR], @job.send(:eligible_visitor_buckets, @project.id).map(&:first),
                 'a never-idle visitor must not be deferred forever'
  end

  test 'defers a visitor whose pending click may still adopt a session' do
    @job.defer_open_sessions = true
    insert_ch_events([event(visitor_id: WEB_VISITOR, at: @now - 1.minute, session_id: '')])

    assert_empty @job.send(:eligible_visitor_buckets, @project.id)
  end

  test 'does not defer a visitor with only SDK events' do
    @job.defer_open_sessions = true
    insert_ch_events([event(visitor_id: APP_VISITOR, at: @now - 1.minute, session_id: 'sdk_abc')])

    assert_equal [APP_VISITOR], @job.send(:eligible_visitor_buckets, @project.id).map(&:first)
  end

  test 'stops deferring once the click can no longer adopt a session' do
    @job.defer_open_sessions = true
    insert_ch_events([event(visitor_id: WEB_VISITOR, at: @now - 2.hours, session_id: '')])

    assert_equal [WEB_VISITOR], @job.send(:eligible_visitor_buckets, @project.id).map(&:first)
  end

  test 'a merged visitor inherits the survivor bucket deferral' do
    @job.defer_open_sessions = true
    insert_ch_events([
      event(visitor_id: WEB_VISITOR, at: @now - 10.minutes, session_id: ''),
      event(visitor_id: APP_VISITOR, at: @now - 1.minute, session_id: 'sdk_abc')
    ])
    merge(WEB_VISITOR, APP_VISITOR)

    assert_empty @job.send(:eligible_visitor_buckets, @project.id),
                 'the click must wait for the app session it may join'
  end

  test 'a session whose visitor is merged away is summarized once, not twice' do
    base = @now - 3.hours
    insert_ch_events([event(visitor_id: APP_VISITOR, at: base, session_id: 'sdk_abc')])
    @job.send(:build_sessions_for_project, @project.id)

    merge(APP_VISITOR, LATER_VISITOR)
    insert_ch_events([event(visitor_id: LATER_VISITOR, at: base + 1.minute, session_id: 'sdk_abc')])
    @job.send(:build_sessions_for_project, @project.id)

    wait_for_ch_mutations('session_summary')

    summaries = ch_query('session_summary', @project.id)
    assert_equal 1, summaries.size, 'one session must not be counted under two visitors'
    assert_equal LATER_VISITOR, summaries.first['visitor_id'].to_i
    assert_equal 2, summaries.first['event_count'].to_i, 'pre-merge events must stay in the session'
  end

  test 'a purchase is not paid into every concurrent session of a merged visitor' do
    base = @now - 3.hours
    insert_ch_events([
      event(visitor_id: APP_VISITOR, at: base, session_id: 'sdk_phone'),
      event(visitor_id: APP_VISITOR, at: base + 10.minutes, session_id: 'sdk_phone'),
      event(visitor_id: LATER_VISITOR, at: base + 1.minute, session_id: 'sdk_tablet'),
      event(visitor_id: LATER_VISITOR, at: base + 9.minutes, session_id: 'sdk_tablet')
    ])
    insert_purchase(visitor_id: LATER_VISITOR, session_id: 'sdk_tablet', at: base + 5.minutes, cents: 999)
    merge(APP_VISITOR, LATER_VISITOR)

    @job.send(:build_sessions_for_project, @project.id)

    summaries = ch_query('session_summary', @project.id)
    assert_equal 999, summaries.sum { |r| r['revenue_usd_cents'].to_i }, 'revenue counted once'
    assert_equal 1, summaries.sum { |r| r['has_conversion'].to_i }, 'one session converted'
  end

  test 'a purchase tagged with an unknown session still falls back to the time window' do
    base = @now - 3.hours
    insert_ch_events([
      event(visitor_id: APP_VISITOR, at: base, session_id: 'sdk_only'),
      event(visitor_id: APP_VISITOR, at: base + 10.minutes, session_id: 'sdk_only')
    ])
    insert_purchase(visitor_id: APP_VISITOR, session_id: 'ghost', at: base + 5.minutes, cents: 999)

    @job.send(:build_sessions_for_project, @project.id)

    summaries = ch_query('session_summary', @project.id)
    assert_equal 999, summaries.sum { |r| r['revenue_usd_cents'].to_i },
                 'an id we did not rebuild must not drop the purchase'
  end

  test 'merging a visitor purges only the sessions this run rewrote' do
    base = @now - 3.hours
    insert_ch_session_summaries([{
      project_id: @project.id, session_id: 'quiet', visitor_id: APP_VISITOR,
      event_date: (@now - 1.day).to_date.to_s,
      started_at: fmt_ch(@now - 1.day), ended_at: fmt_ch(@now - 1.day)
    }])
    insert_ch_events([
      event(visitor_id: APP_VISITOR, at: base, session_id: 'sdk_rewritten'),
      event(visitor_id: LATER_VISITOR, at: base + 1.minute, session_id: 'sdk_rewritten')
    ])
    merge(APP_VISITOR, LATER_VISITOR)

    @job.send(:build_sessions_for_project, @project.id)
    wait_for_ch_mutations('session_summary')

    kept = ch_query('session_summary', @project.id).map { |r| r['session_id'] }
    assert_includes kept, 'quiet', 'a session this run never rebuilt must survive the merge'
    assert_equal 1, kept.count('sdk_rewritten'), 'the rewritten session keeps one row'
  end

  test 'an already-sessionized older click does not release a fresh one' do
    insert_ch_events([event(visitor_id: WEB_VISITOR, at: @now - 90.minutes, session_id: '')])
    @job.send(:build_sessions_for_project, @project.id)

    insert_ch_events([event(visitor_id: WEB_VISITOR, at: @now - 2.minutes, session_id: '')])
    @job.defer_open_sessions = true

    assert_empty @job.send(:eligible_visitor_buckets, @project.id),
                 'the fresh click must still be protected'
  end

  test 'stops waiting once the click is older than the gap it could adopt across' do
    @job.defer_open_sessions = true
    insert_ch_events([
      event(visitor_id: WEB_VISITOR, at: @now - 40.minutes, session_id: ''),
      event(visitor_id: APP_VISITOR, at: @now - 1.minute, session_id: 'sdk_abc')
    ])
    merge(WEB_VISITOR, APP_VISITOR)

    assert_equal [APP_VISITOR], @job.send(:eligible_visitor_buckets, @project.id).map(&:first),
                 'nothing arriving now could join a click that old'
  end

  private

  def seed_journey(install_offset:)
    base = @now - 3.hours
    insert_ch_events([
      event(visitor_id: WEB_VISITOR, at: base, session_id: '', event_type: 'VIEW',
            link_id: 77, platform: 'web', app_version: ''),
      event(visitor_id: APP_VISITOR, at: base + install_offset, session_id: 'sdk_abc',
            event_type: 'INSTALL', platform: 'ios', app_version: '2.0'),
      event(visitor_id: APP_VISITOR, at: base + install_offset + 1.minute, session_id: 'sdk_abc',
            event_type: 'APP_OPEN', platform: 'ios', app_version: '2.0')
    ])
  end

  def event(visitor_id:, at:, session_id:, event_type: 'VIEW', link_id: 0, platform: 'ios', app_version: '1.0')
    {
      project_id: @project.id,
      event_id: SecureRandom.uuid,
      event_type: event_type,
      event_name: '',
      screen_name: '',
      visitor_id: visitor_id,
      device_id: 1,
      platform: platform,
      app_version: app_version,
      country: 'US',
      link_id: link_id,
      session_id: session_id,
      created_at: at.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    }
  end

  def ch_row(visitor_id, at, session_id)
    { 'visitor_id' => visitor_id, 'created_at' => at.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'),
      'session_id' => session_id, 'event_id' => SecureRandom.uuid, 'event_type' => 'VIEW',
      'device_id' => 1, 'properties' => {} }
  end


  def wait_for_ch_mutations(table)
    20.times do
      pending = Clickhouse.with do |conn|
        conn.select_value("SELECT count() FROM system.mutations WHERE database = currentDatabase() " \
                          "AND table = '#{table}' AND is_done = 0")
      end
      break if pending.to_i.zero?

      sleep 0.05
    end
  end

  def fmt_ch(time)
    time.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
  end

  def insert_purchase(visitor_id:, session_id:, at:, cents:)
    Clickhouse.with do |conn|
      conn.insert('purchase_events',
                  [{ project_id: @project.id, visitor_id: visitor_id, session_id: session_id,
                     transaction_id: SecureRandom.uuid, event_type: Grovs::Purchases::EVENT_BUY,
                     usd_price_cents: cents, created_at: fmt_ch(at) }])
    end
  end

  def merge(from, to)
    Clickhouse.with do |conn|
      conn.insert('visitor_identity_map',
                  [{ project_id: @project.id, from_visitor_id: from, to_visitor_id: to,
                     updated_at: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }])
    end
  end
end
