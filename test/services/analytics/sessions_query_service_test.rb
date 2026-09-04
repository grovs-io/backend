# frozen_string_literal: true

require 'test_helper'

class Analytics::SessionsQueryServiceTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  PID = 9_910

  setup do
    skip_unless_clickhouse!
  end

  test 'list returns sessions for the project ordered newest-first with cursor' do
    insert_ch_session_summaries([
      { project_id: PID, session_id: 's1', visitor_id: 1, event_date: '2026-05-01',
        started_at: '2026-05-01 10:00:00.000', ended_at: '2026-05-01 10:05:00.000',
        duration_ms: 300_000, event_count: 4, platform: 'ios', app_version: '2.0.0',
        country: 'US', link_id: 7, campaign_id: 0, sdk_generated: 0, link_visitor_id: 0,
        tracking_source: 'links', has_conversion: 0, revenue_usd_cents: 0 },
      { project_id: PID, session_id: 's2', visitor_id: 2, event_date: '2026-05-02',
        started_at: '2026-05-02 10:00:00.000', ended_at: '2026-05-02 10:02:00.000',
        duration_ms: 120_000, event_count: 2, platform: 'android', app_version: '2.1.0',
        country: 'DE', link_id: 0, campaign_id: 3, sdk_generated: 0, link_visitor_id: 0,
        tracking_source: 'campaigns', has_conversion: 1, revenue_usd_cents: 999 }
    ])

    result = Analytics::SessionsQueryService.list(
      PID, start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 5, 31), limit: 50
    )

    assert_equal %w[s2 s1], result[:data].map { |r| r['session_id'] }
    assert_nil result[:next_cursor]
    first = result[:data].first
    assert_equal 'android', first['platform']
    assert_equal 999, first['revenue_usd_cents'].to_i
    assert_equal 'campaigns', first['source'], 'computed source category present'

    # Every row exposes an opaque, decodable detail key (frontend contract).
    assert(first['id'].present?, 'list row exposes opaque id')
    decoded = Analytics::SessionsQueryService.decode_key(first['id'])
    assert_equal 's2', decoded[:session_id]
    assert_equal 2, decoded[:visitor_id]
    assert_equal '2026-05-02', decoded[:event_date]
  end

  test 'list displays desktop platforms as web and filter web matches them' do
    insert_ch_session_summaries([
      { project_id: PID, session_id: 'plat_mac', visitor_id: 1, event_date: '2026-05-01',
        started_at: '2026-05-01 10:00:00.000', ended_at: '2026-05-01 10:01:00.000',
        platform: 'mac', campaign_id: 0, link_id: 0, sdk_generated: 0, link_visitor_id: 0 },
      { project_id: PID, session_id: 'plat_ios', visitor_id: 2, event_date: '2026-05-01',
        started_at: '2026-05-01 11:00:00.000', ended_at: '2026-05-01 11:01:00.000',
        platform: 'ios', campaign_id: 0, link_id: 0, sdk_generated: 0, link_visitor_id: 0 }
    ])

    result = Analytics::SessionsQueryService.list(
      PID, start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 5, 31)
    )
    by_id = result[:data].index_by { |r| r['session_id'] }
    assert_equal 'web', by_id['plat_mac']['platform']
    assert_equal 'ios', by_id['plat_ios']['platform']

    filtered = Analytics::SessionsQueryService.list(
      PID, start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 5, 31),
      filters: [{ 'field' => 'platform', 'operator' => 'is', 'value' => 'web' }]
    )
    assert_equal ['plat_mac'], filtered[:data].map { |r| r['session_id'] }
  end

  test 'list filters by derived source category' do
    insert_ch_session_summaries([
      { project_id: PID, session_id: 'camp', visitor_id: 1, event_date: '2026-05-01',
        started_at: '2026-05-01 10:00:00.000', ended_at: '2026-05-01 10:01:00.000',
        campaign_id: 3, link_id: 0, sdk_generated: 0, link_visitor_id: 0 },
      { project_id: PID, session_id: 'org', visitor_id: 2, event_date: '2026-05-01',
        started_at: '2026-05-01 11:00:00.000', ended_at: '2026-05-01 11:01:00.000',
        campaign_id: 0, link_id: 0, sdk_generated: 0, link_visitor_id: 0 }
    ])

    result = Analytics::SessionsQueryService.list(
      PID, start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 5, 31), source: 'campaigns'
    )
    assert_equal ['camp'], result[:data].map { |r| r['session_id'] }
  end

  test 'list ignores invalid source category instead of filtering everything out' do
    insert_ch_session_summaries([
      { project_id: PID, session_id: 'camp', visitor_id: 1, event_date: '2026-05-01',
        started_at: '2026-05-01 10:00:00.000', ended_at: '2026-05-01 10:01:00.000',
        campaign_id: 3, link_id: 0, sdk_generated: 0, link_visitor_id: 0 },
      { project_id: PID, session_id: 'org', visitor_id: 2, event_date: '2026-05-01',
        started_at: '2026-05-01 11:00:00.000', ended_at: '2026-05-01 11:01:00.000',
        campaign_id: 0, link_id: 0, sdk_generated: 0, link_visitor_id: 0 }
    ])

    result = Analytics::SessionsQueryService.list(
      PID, start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 5, 31), source: 'not-real'
    )

    assert_equal %w[org camp], result[:data].map { |row| row['session_id'] }
  end

  test 'list filters each derived source category without cross-contamination' do
    insert_ch_session_summaries([
      { project_id: PID, session_id: 'ref', visitor_id: 1, event_date: '2026-05-01',
        started_at: '2026-05-01 10:00:00.000', ended_at: '2026-05-01 10:01:00.000',
        campaign_id: 0, link_id: 10, sdk_generated: 1, link_visitor_id: 99 },
      { project_id: PID, session_id: 'api', visitor_id: 2, event_date: '2026-05-01',
        started_at: '2026-05-01 11:00:00.000', ended_at: '2026-05-01 11:01:00.000',
        campaign_id: 0, link_id: 11, sdk_generated: 1, link_visitor_id: 0 },
      { project_id: PID, session_id: 'link', visitor_id: 3, event_date: '2026-05-01',
        started_at: '2026-05-01 12:00:00.000', ended_at: '2026-05-01 12:01:00.000',
        campaign_id: 0, link_id: 12, sdk_generated: 0, link_visitor_id: 0 },
      { project_id: PID, session_id: 'organic', visitor_id: 4, event_date: '2026-05-01',
        started_at: '2026-05-01 13:00:00.000', ended_at: '2026-05-01 13:01:00.000',
        campaign_id: 0, link_id: 0, sdk_generated: 0, link_visitor_id: 0 }
    ])

    expected = {
      'referrals' => ['ref'],
      'api_links' => ['api'],
      'links' => ['link'],
      'organic' => ['organic']
    }
    expected.each do |source, session_ids|
      result = Analytics::SessionsQueryService.list(
        PID,
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 5, 31),
        source: source
      )
      assert_equal session_ids, result[:data].map { |row| row['session_id'] }, "source=#{source}"
    end
  end

  test 'list returns an empty result instead of raising when ClickHouse read fails' do
    Clickhouse.stub(:with, -> { raise StandardError, 'clickhouse unavailable' }) do
      assert_equal(
        { data: [], next_cursor: nil },
        Analytics::SessionsQueryService.list(PID, start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 5, 31))
      )
    end
  end

  test 'list ignores decoded session cursor missing visitor id instead of raising' do
    insert_ch_session_summaries({
      project_id: PID,
      session_id: 'safe_cursor_session',
      visitor_id: 1,
      event_date: '2026-05-01',
      started_at: '2026-05-01 10:00:00.000',
      ended_at: '2026-05-01 10:01:00.000'
    })
    cursor = Base64.urlsafe_encode64({ t: '2026-05-01 10:00:00.000', s: 'safe_cursor_session' }.to_json, padding: false)

    result = Analytics::SessionsQueryService.list(
      PID,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 2),
      cursor: cursor
    )

    assert_equal ['safe_cursor_session'], result[:data].map { |row| row['session_id'] }
  end

  test 'list ignores decoded session cursor with non-integer visitor id instead of raising' do
    insert_ch_session_summaries({
      project_id: PID,
      session_id: 'safe_bad_visitor_cursor',
      visitor_id: 1,
      event_date: '2026-05-01',
      started_at: '2026-05-01 10:00:00.000',
      ended_at: '2026-05-01 10:01:00.000'
    })
    cursor = Base64.urlsafe_encode64(
      { t: '2026-05-01 10:00:00.000', s: 'safe_bad_visitor_cursor', v: 'not-an-int' }.to_json,
      padding: false
    )

    result = Analytics::SessionsQueryService.list(
      PID,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 2),
      cursor: cursor
    )

    assert_equal ['safe_bad_visitor_cursor'], result[:data].map { |row| row['session_id'] }
  end

  test 'list isolates by project_id' do
    insert_ch_session_summaries({ project_id: PID, session_id: 'mine', visitor_id: 1,
      event_date: '2026-05-01', started_at: '2026-05-01 10:00:00.000', ended_at: '2026-05-01 10:01:00.000' })
    insert_ch_session_summaries({ project_id: PID + 1, session_id: 'theirs', visitor_id: 1,
      event_date: '2026-05-01', started_at: '2026-05-01 10:00:00.000', ended_at: '2026-05-01 10:01:00.000' })

    result = Analytics::SessionsQueryService.list(
      PID, start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 5, 31)
    )
    assert_equal ['mine'], result[:data].map { |r| r['session_id'] }
  end

  # Proves the cursor compares the full (started_at, session_id, visitor_id) tuple:
  # two visitors share session_id AND started_at; paging by 1 must visit both once.
  test 'list pagination does not skip or duplicate rows tied on started_at + session_id' do
    insert_ch_session_summaries([
      { project_id: PID, session_id: 'tie', visitor_id: 1, event_date: '2026-05-01',
        started_at: '2026-05-01 10:00:00.000', ended_at: '2026-05-01 10:01:00.000' },
      { project_id: PID, session_id: 'tie', visitor_id: 2, event_date: '2026-05-01',
        started_at: '2026-05-01 10:00:00.000', ended_at: '2026-05-01 10:01:00.000' }
    ])

    seen = []
    cursor = nil
    3.times do
      page = Analytics::SessionsQueryService.list(
        PID, start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 5, 31), limit: 1, cursor: cursor
      )
      break if page[:data].empty?

      seen.concat(page[:data].map { |r| [r['session_id'], r['visitor_id'].to_i] })
      cursor = page[:next_cursor]
      break if cursor.nil?
    end

    assert_equal [['tie', 1], ['tie', 2]], seen.sort_by { |_, v| v }
    assert_equal seen.uniq.size, seen.size, 'no duplicates across pages'
  end

  test 'find returns session facts plus ordered events, scoped to project + visitor' do
    insert_ch_session_summaries({ project_id: PID, session_id: 'sx', visitor_id: 5,
      event_date: '2026-05-01', started_at: '2026-05-01 10:00:00.000', ended_at: '2026-05-01 10:03:00.000',
      duration_ms: 180_000, event_count: 2, platform: 'ios' })
    insert_ch_session_events([
      { project_id: PID, session_id: 'sx', visitor_id: 5, event_type: 'OPEN',
        created_at: '2026-05-01 10:00:00.000' },
      { project_id: PID, session_id: 'sx', visitor_id: 5, event_type: 'VIEW',
        created_at: '2026-05-01 10:01:00.000', screen_name: 'Home' }
    ])

    result = Analytics::SessionsQueryService.find(PID, session_id: 'sx', visitor_id: 5, event_date: '2026-05-01')
    assert_equal 'sx', result[:session]['session_id']
    assert_equal 'organic', result[:session]['source'], 'detail includes computed source'
    assert_equal 2, result[:events].size
    assert_equal %w[OPEN VIEW], result[:events].map { |e| e['event_type'] }
  end

  # The same visitor reuses one session_id on two different days → two distinct
  # session_summary rows (event_date is part of the dedup key). find must address
  # exactly one instance and must NOT merge the other day's events.
  test 'find does not merge a session_id reused by the same visitor across dates' do
    insert_ch_session_summaries([
      { project_id: PID, session_id: 'reused', visitor_id: 7, event_date: '2026-05-01',
        started_at: '2026-05-01 10:00:00.000', ended_at: '2026-05-01 10:05:00.000', platform: 'ios' },
      { project_id: PID, session_id: 'reused', visitor_id: 7, event_date: '2026-05-05',
        started_at: '2026-05-05 10:00:00.000', ended_at: '2026-05-05 10:05:00.000', platform: 'android' }
    ])
    insert_ch_session_events([
      { project_id: PID, session_id: 'reused', visitor_id: 7, event_type: 'OPEN', created_at: '2026-05-01 10:00:00.000' },
      { project_id: PID, session_id: 'reused', visitor_id: 7, event_type: 'VIEW', created_at: '2026-05-05 10:00:00.000' }
    ])

    day1 = Analytics::SessionsQueryService.find(PID, session_id: 'reused', visitor_id: 7, event_date: '2026-05-01')
    assert_equal 'ios', day1[:session]['platform']
    assert_equal ['OPEN'], day1[:events].map { |e| e['event_type'] }, 'only day-1 events'

    day5 = Analytics::SessionsQueryService.find(PID, session_id: 'reused', visitor_id: 7, event_date: '2026-05-05')
    assert_equal 'android', day5[:session]['platform']
    assert_equal ['VIEW'], day5[:events].map { |e| e['event_type'] }, 'only day-5 events'
  end

  # The critical isolation case: two visitors share an arbitrary SDK session_id.
  test 'find does not mix visitors that share a session_id' do
    insert_ch_session_summaries([
      { project_id: PID, session_id: 'shared', visitor_id: 5, event_date: '2026-05-01',
        started_at: '2026-05-01 10:00:00.000', ended_at: '2026-05-01 10:01:00.000', platform: 'ios' },
      { project_id: PID, session_id: 'shared', visitor_id: 9, event_date: '2026-05-01',
        started_at: '2026-05-01 11:00:00.000', ended_at: '2026-05-01 11:01:00.000', platform: 'android' }
    ])
    insert_ch_session_events([
      { project_id: PID, session_id: 'shared', visitor_id: 5, event_type: 'OPEN', created_at: '2026-05-01 10:00:00.000' },
      { project_id: PID, session_id: 'shared', visitor_id: 9, event_type: 'VIEW', created_at: '2026-05-01 11:00:00.000' }
    ])

    r5 = Analytics::SessionsQueryService.find(PID, session_id: 'shared', visitor_id: 5, event_date: '2026-05-01')
    assert_equal 'ios', r5[:session]['platform']
    assert_equal ['OPEN'], r5[:events].map { |e| e['event_type'] }

    r9 = Analytics::SessionsQueryService.find(PID, session_id: 'shared', visitor_id: 9, event_date: '2026-05-01')
    assert_equal 'android', r9[:session]['platform']
    assert_equal ['VIEW'], r9[:events].map { |e| e['event_type'] }
  end

  test 'find returns nil for a session belonging to another project' do
    insert_ch_session_summaries({ project_id: PID + 1, session_id: 'foreign', visitor_id: 1,
      event_date: '2026-05-01', started_at: '2026-05-01 10:00:00.000', ended_at: '2026-05-01 10:01:00.000' })
    assert_nil Analytics::SessionsQueryService.find(PID, session_id: 'foreign', visitor_id: 1, event_date: '2026-05-01')
  end

  test 'find returns nil instead of raising when ClickHouse read fails' do
    Clickhouse.stub(:with, -> { raise StandardError, 'clickhouse unavailable' }) do
      assert_nil Analytics::SessionsQueryService.find(PID, session_id: 'sx', visitor_id: 5, event_date: '2026-05-01')
    end
  end

  # Matches the codebase convention (QueryHelpers::PROPAGATED_ERRORS): bad-type input
  # raises rather than silently returning empty, so callers never mask a programming error.
  test 'list propagates ArgumentError for a non-integer project id' do
    assert_raises(ArgumentError) do
      Analytics::SessionsQueryService.list('not-an-int', start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 5, 31))
    end
  end

  test 'list applies plain-column filters (platform)' do
    insert_ch_session_summaries([
      { project_id: PID, session_id: 'ios1', visitor_id: 1, event_date: '2026-05-01',
        started_at: '2026-05-01 10:00:00.000', ended_at: '2026-05-01 10:01:00.000', platform: 'ios' },
      { project_id: PID, session_id: 'and1', visitor_id: 2, event_date: '2026-05-01',
        started_at: '2026-05-01 11:00:00.000', ended_at: '2026-05-01 11:01:00.000', platform: 'android' }
    ])

    result = Analytics::SessionsQueryService.list(
      PID, start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 5, 31),
      filters: [{ 'field' => 'platform', 'operator' => 'is', 'value' => 'ios' }]
    )
    assert_equal ['ios1'], result[:data].map { |r| r['session_id'] }
  end
end

# Pure key encode/decode — no ClickHouse required, so this always runs (even in CI
# without a CH instance), locking the opaque-detail-key contract.
class Analytics::SessionsKeyTest < ActiveSupport::TestCase
  test 'encode_key/decode_key round-trips the full (session_id, visitor_id, event_date) triple' do
    key = Analytics::SessionsQueryService.encode_key('sess/with spaces+weird', 42, '2026-05-01')
    assert_match(/\A[A-Za-z0-9_-]+\z/, key, 'key is URL-safe and slash-free')
    assert_equal({ session_id: 'sess/with spaces+weird', visitor_id: 42, event_date: '2026-05-01' },
                 Analytics::SessionsQueryService.decode_key(key))
  end

  test 'decode_key rejects garbage, blanks, and partial payloads' do
    svc = Analytics::SessionsQueryService
    assert_nil svc.decode_key('not-base64!!')
    assert_nil svc.decode_key('')
    assert_nil svc.decode_key(nil)
    # Valid base64url of a non-object / partial payloads → nil (no crash)
    assert_nil svc.decode_key(Base64.urlsafe_encode64('[1,2,3]', padding: false))
    assert_nil svc.decode_key(Base64.urlsafe_encode64({ s: 'x', v: 1 }.to_json, padding: false)) # missing d
    assert_nil svc.decode_key(Base64.urlsafe_encode64({ s: '', v: 1, d: '2026-05-01' }.to_json, padding: false))
  end

  # A forged key with a non-parseable date must decode to nil (→ controller 400),
  # not pass through to find() where sanitize_date_value would raise Date::Error
  # (a propagated error → uncaught 500).
  test 'decode_key rejects a non-parseable event_date' do
    svc = Analytics::SessionsQueryService
    forged = Base64.urlsafe_encode64({ s: 'x', v: 1, d: 'not-a-date' }.to_json, padding: false)
    assert_nil svc.decode_key(forged)
  end
end
