# frozen_string_literal: true

require 'test_helper'

class Analytics::EventsQueryTimezoneTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances

  PROJECT_ID = 918_273

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
  end

  teardown { truncate_clickhouse_tables }

  test 'hour buckets are cut in the requested zone' do
    insert_ch_events(project_id: PROJECT_ID, event_type: 'app_open',
                     created_at: '2026-04-24 22:30:00.000')

    utc = Analytics::EventsQueryService.volume(
      PROJECT_ID, start_date: '2026-04-24', end_date: '2026-04-25', bucket: 'hour', timezone: 'UTC'
    )
    bucharest = Analytics::EventsQueryService.volume(
      PROJECT_ID, start_date: '2026-04-24', end_date: '2026-04-25', bucket: 'hour',
      timezone: 'Europe/Bucharest'
    )

    assert_equal '2026-04-24 22:00:00', utc[:buckets].first['bucket']
    assert_equal '2026-04-25 01:00:00', bucharest[:buckets].first['bucket']
  end

  test 'a late-evening UTC event lands on the next local day' do
    insert_ch_events(project_id: PROJECT_ID, event_type: 'app_open',
                     created_at: '2026-04-24 23:15:00.000')

    # Bounds are the Tokyo day expressed as instants — the pairing the dashboard sends.
    result = Analytics::EventsQueryService.volume(
      PROJECT_ID, start_date: Time.utc(2026, 4, 24, 15), end_date: Time.utc(2026, 4, 25, 15),
      bucket: 'day', timezone: 'Asia/Tokyo'
    )

    assert_equal '2026-04-25', result[:buckets].first['bucket'].to_s
  end

  test 'an unknown zone falls back to UTC rather than blanking the chart' do
    insert_ch_events(project_id: PROJECT_ID, event_type: 'app_open',
                     created_at: '2026-04-24 22:30:00.000')

    result = Analytics::EventsQueryService.volume(
      PROJECT_ID, start_date: '2026-04-24', end_date: '2026-04-25', bucket: 'hour',
      timezone: "Nowhere/Fake'--"
    )

    assert_equal '2026-04-24 22:00:00', result[:buckets].first['bucket']
  end

  test 'the range end is exclusive at millisecond precision' do
    insert_ch_events([
                       { project_id: PROJECT_ID, event_type: 'app_open',
                         created_at: '2026-04-24 23:59:59.500' },
                       { project_id: PROJECT_ID, event_type: 'app_open',
                         created_at: '2026-04-25 00:00:00.000' }
                     ])

    result = Analytics::EventsQueryService.list(
      PROJECT_ID, start_date: Time.utc(2026, 4, 24), end_date: Time.utc(2026, 4, 25), limit: 10
    )

    assert_equal 1, result[:data].size, 'the instant equal to end_date must be excluded'
  end

  test 'a bare date end still covers the whole of that day' do
    insert_ch_events(project_id: PROJECT_ID, event_type: 'app_open',
                     created_at: '2026-04-24 23:59:59.500')

    result = Analytics::EventsQueryService.list(
      PROJECT_ID, start_date: '2026-04-24', end_date: '2026-04-24', limit: 10
    )

    assert_equal 1, result[:data].size
  end
end
