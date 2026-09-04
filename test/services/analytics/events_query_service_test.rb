# frozen_string_literal: true

require 'test_helper'

class Analytics::EventsQueryServiceTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :domains, :links, :campaigns

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @now = Time.current
  end

  # --- list ---

  test 'list returns events within date range' do
    insert_test_events
    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current,
      include_count: true
    )
    assert result[:data].size > 0
    assert_not_nil result[:total_count]
  end

  test 'list omits total_count by default' do
    insert_test_events
    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current
    )
    assert result[:data].size > 0
    assert_nil result[:total_count]
  end

  test 'list with filter is reduces results' do
    insert_test_events
    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current,
      filters: [{ 'field' => 'event_type', 'operator' => 'is', 'value' => 'VIEW' }]
    )
    result[:data].each do |event|
      assert_equal 'VIEW', event['event_type']
    end
  end

  test 'list with filter is_not excludes matching' do
    insert_test_events
    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current,
      filters: [{ 'field' => 'event_type', 'operator' => 'is_not', 'value' => 'VIEW' }]
    )
    result[:data].each do |event|
      assert_not_equal 'VIEW', event['event_type']
    end
  end

  test 'list with contains filter matches substring' do
    insert_test_events
    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current,
      filters: [{ 'field' => 'event_name', 'operator' => 'contains', 'value' => 'screen' }]
    )
    result[:data].each do |event|
      assert_match(/screen/i, event['event_name'])
    end
  end

  test 'search treats SQL-looking values as escaped literals' do
    insert_ch_events([
      base_event(event_id: 'safe_ios', event_name: 'purchase_completed', screen_name: 'Checkout'),
      base_event(event_id: 'safe_android', event_name: 'login', screen_name: 'Home')
    ])

    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current,
      search: "purchase%' OR 1=1 --"
    )

    assert_equal [], result[:data]
  end

  test 'list cursor pagination returns subsequent page' do
    insert_test_events(count: 10)
    first_page = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current,
      limit: 3
    )
    assert_equal 3, first_page[:data].size
    assert_not_nil first_page[:next_cursor]

    second_page = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current,
      limit: 3,
      cursor: first_page[:next_cursor]
    )
    assert second_page[:data].size > 0
    # No overlap between pages
    first_ids = first_page[:data].map { |e| e['event_id'] }
    second_ids = second_page[:data].map { |e| e['event_id'] }
    assert_empty first_ids & second_ids
  end

  test 'list supports ascending sort order for stable chronological browsing' do
    insert_ch_events([
      base_event(event_id: 'sort_older', event_name: 'older', platform: 'ios', created_at: '2026-05-01 10:00:00.000'),
      base_event(event_id: 'sort_newer', event_name: 'newer', platform: 'android', created_at: '2026-05-01 11:00:00.000')
    ])

    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 1),
      sort_by: 'created_at',
      sort_order: 'asc',
      limit: 2
    )

    assert_equal %w[sort_older sort_newer], result[:data].map { |row| row['event_id'] }
  end

  test 'list cursor pagination works with ascending sort order' do
    insert_ch_events([
      base_event(event_id: 'asc_1', created_at: '2026-05-01 10:00:00.000'),
      base_event(event_id: 'asc_2', created_at: '2026-05-01 11:00:00.000'),
      base_event(event_id: 'asc_3', created_at: '2026-05-01 12:00:00.000')
    ])

    first_page = Analytics::EventsQueryService.list(
      @project.id,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 1),
      sort_order: 'asc',
      limit: 1
    )
    second_page = Analytics::EventsQueryService.list(
      @project.id,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 1),
      sort_order: 'asc',
      limit: 2,
      cursor: first_page[:next_cursor]
    )

    assert_equal ['asc_1'], first_page[:data].map { |row| row['event_id'] }
    assert_equal %w[asc_2 asc_3], second_page[:data].map { |row| row['event_id'] }
  end

  test 'list falls back to safe defaults for invalid sort inputs' do
    insert_ch_events([
      base_event(event_id: 'fallback_old', created_at: '2026-05-01 10:00:00.000'),
      base_event(event_id: 'fallback_new', created_at: '2026-05-01 11:00:00.000')
    ])

    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 1),
      sort_by: 'created_at; DROP TABLE events',
      sort_order: 'sideways',
      limit: 2
    )

    assert_equal %w[fallback_new fallback_old], result[:data].map { |row| row['event_id'] }
  end

  test 'list with invalid cursor returns empty gracefully' do
    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current,
      cursor: 'not-valid-base64!!!'
    )
    # Invalid cursor is silently ignored (decoded to nil)
    assert_kind_of Hash, result
  end

  test 'list ignores decoded cursor missing required keys instead of raising' do
    insert_ch_events([
      base_event(event_id: 'evt_cursor_safe', created_at: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'))
    ])
    cursor = Base64.urlsafe_encode64({ t: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }.to_json, padding: false)

    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current,
      cursor: cursor
    )

    assert_equal ['evt_cursor_safe'], result[:data].map { |row| row['event_id'] }
  end

  test 'list returns an empty result instead of raising when ClickHouse read fails' do
    Clickhouse.stub(:with, -> { raise StandardError, 'clickhouse unavailable' }) do
      result = Analytics::EventsQueryService.list(
        @project.id,
        start_date: 7.days.ago.to_date,
        end_date: Date.current,
        include_count: true
      )

      assert_equal({ data: [], next_cursor: nil, total_count: 0 }, result)
    end
  end

  test 'list returns rows with total_count nil when only the count times out' do
    truncate_clickhouse_tables
    insert_ch_events([base_event(event_id: 'count_degrade', event_type: 'OPEN',
                                 created_at: '2026-06-01 00:00:00.000')])

    # Stub only the count path to raise QueryTooHeavy; the data query runs for real.
    real = Analytics::EventsQueryService.method(:with_guard)
    Analytics::EventsQueryService.stub(:with_guard, lambda { |sql|
      raise Analytics::QueryTooHeavy, 'count too heavy' if sql.include?('count()')

      real.call(sql)
    }) do
      result = Analytics::EventsQueryService.list(
        @project.id,
        start_date: Date.new(2026, 6, 1),
        end_date: Date.new(2026, 6, 2),
        include_count: true
      )
      assert_equal 1, result[:data].size
      assert_equal 'count_degrade', result[:data].first['event_id']
      assert_nil result[:total_count]
    end
  end

  # Mirror of the count-degradation test, locking the asymmetry: a heavy DATA query
  # must PROPAGATE QueryTooHeavy (→ controller 422), unlike the count query which
  # degrades to total_count: nil. Only the count query is wrapped in a QueryTooHeavy
  # rescue; the data query is not. This fails if someone widens that rescue to also
  # swallow the data query.
  test 'list propagates QueryTooHeavy when the data query is too heavy' do
    truncate_clickhouse_tables
    insert_ch_events([base_event(event_id: 'data_heavy', created_at: '2026-06-01 00:00:00.000')])

    # Stub only the data path to raise QueryTooHeavy; the count query (if reached) runs for real.
    real = Analytics::EventsQueryService.method(:with_guard)
    Analytics::EventsQueryService.stub(:with_guard, lambda { |sql|
      raise Analytics::QueryTooHeavy, 'data query too heavy' unless sql.include?('count()')

      real.call(sql)
    }) do
      assert_raises(Analytics::QueryTooHeavy) do
        Analytics::EventsQueryService.list(
          @project.id,
          start_date: Date.new(2026, 6, 1),
          end_date: Date.new(2026, 6, 2),
          include_count: true
        )
      end
    end
  end

  test 'list returns a real integer total_count through the guard on the happy path' do
    truncate_clickhouse_tables
    insert_ch_events([
      base_event(event_id: 'count_real_1', created_at: '2026-06-01 00:00:00.000'),
      base_event(event_id: 'count_real_2', created_at: '2026-06-01 01:00:00.000')
    ])

    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: Date.new(2026, 6, 1),
      end_date: Date.new(2026, 6, 2),
      include_count: true
    )

    assert_equal 2, result[:data].size
    assert_equal 2, result[:total_count]
  end

  test 'list keeps properties in the response shape without reading the JSON column' do
    captured_sql = nil

    Analytics::EventsQueryService.stub(:with_guard, lambda { |sql|
      captured_sql = sql
      []
    }) do
      Analytics::EventsQueryService.list(
        @project.id,
        start_date: Date.new(2026, 1, 1),
        end_date: Date.new(2026, 1, 31)
      )
    end

    select_list = captured_sql[/SELECT\s+(.*?)\s+FROM events\b/m, 1]
    assert_includes select_list, 'NULL AS properties'
    assert_no_match(/(?:^|,\s*)properties(?:\s*,|$)/, select_list)
  end

  test 'list reads the fast explorer table without FINAL' do
    captured_sql = nil

    Analytics::EventsQueryService.stub(:with_guard, lambda { |sql|
      captured_sql = sql
      []
    }) do
      Analytics::EventsQueryService.list(
        @project.id,
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 18),
        filters: [{ 'field' => 'visitor_id', 'operator' => 'is', 'value' => '289171' }]
      )
    end

    assert_match(/FROM events\s+WHERE/m, captured_sql)
    assert_no_match(/FROM events\s+FINAL/i, captured_sql)
    assert_includes captured_sql, 'visitor_id = 289171'
    assert_includes captured_sql, 'event_id IN (SELECT DISTINCT event_id FROM events'
    assert_includes captured_sql, 'LIMIT 1 BY event_id'
  end

  test 'list bounds unfiltered created_at browsing to recent event candidates' do
    captured_sql = nil

    Analytics::EventsQueryService.stub(:with_guard, lambda { |sql|
      captured_sql = sql
      []
    }) do
      Analytics::EventsQueryService.list(
        @project.id,
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 18),
        sort_by: 'created_at',
        sort_order: 'desc'
      )
    end

    assert_includes captured_sql, 'event_id IN (SELECT event_id FROM events'
    assert_includes captured_sql, 'ORDER BY created_at DESC, event_id DESC, ingested_at DESC'
    assert_includes captured_sql, 'LIMIT 1 BY event_id LIMIT 1000'
    assert_includes captured_sql, 'LIMIT 1 BY event_id'
  end

  test 'list applies cursor inside unfiltered recent candidate selection' do
    captured_sql = nil
    cursor = Base64.urlsafe_encode64(
      { t: '2026-04-10 12:00:00.000', id: 'evt_cursor' }.to_json,
      padding: false
    )

    Analytics::EventsQueryService.stub(:with_guard, lambda { |sql|
      captured_sql = sql
      []
    }) do
      Analytics::EventsQueryService.list(
        @project.id,
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 18),
        cursor: cursor,
        sort_by: 'created_at',
        sort_order: 'desc'
      )
    end

    assert_includes captured_sql, "created_at < '2026-04-10 12:00:00.000'"
    assert_includes captured_sql, 'event_id IN (SELECT event_id FROM events'
    assert_includes captured_sql, 'LIMIT 1 BY event_id LIMIT 1000'
  end

  test 'list collapses duplicate event deliveries without FINAL' do
    truncate_clickhouse_tables
    insert_ch_events([
      base_event(event_id: 'dedupe_list', event_name: 'older',
                 created_at: '2026-04-10 10:00:00.000',
                 ingested_at: '2026-04-10 10:00:01.000'),
      base_event(event_id: 'dedupe_list', event_name: 'newer',
                 created_at: '2026-04-10 10:00:00.000',
                 ingested_at: '2026-04-10 10:00:02.000')
    ])

    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 18),
      filters: [{ 'field' => 'visitor_id', 'operator' => 'is', 'value' => '0' }]
    )

    assert_equal ['dedupe_list'], result[:data].map { |row| row['event_id'] }
    assert_equal 'newer', result[:data].first['event_name']
  end

  test 'list chooses latest duplicate version before sorting by mutable columns' do
    truncate_clickhouse_tables
    insert_ch_events([
      base_event(event_id: 'mutable_sort', event_name: 'aaa_old',
                 created_at: '2026-04-10 10:00:00.000',
                 ingested_at: '2026-04-10 10:00:01.000'),
      base_event(event_id: 'mutable_sort', event_name: 'zzz_new',
                 created_at: '2026-04-10 10:00:00.000',
                 ingested_at: '2026-04-10 10:00:02.000')
    ])

    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 18),
      sort_by: 'event_name',
      sort_order: 'asc',
      filters: [{ 'field' => 'visitor_id', 'operator' => 'is', 'value' => '0' }]
    )

    assert_equal ['mutable_sort'], result[:data].map { |row| row['event_id'] }
    assert_equal 'zzz_new', result[:data].first['event_name']
  end

  test 'list applies mutable filters after choosing latest duplicate version' do
    truncate_clickhouse_tables
    insert_ch_events([
      base_event(event_id: 'mutable_filter', event_name: 'stale_match',
                 created_at: '2026-04-10 10:00:00.000',
                 ingested_at: '2026-04-10 10:00:01.000'),
      base_event(event_id: 'mutable_filter', event_name: 'latest_no_match',
                 created_at: '2026-04-10 10:00:00.000',
                 ingested_at: '2026-04-10 10:00:02.000')
    ])

    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 18),
      filters: [{ 'field' => 'event_name', 'operator' => 'is', 'value' => 'stale_match' }]
    )

    assert_empty result[:data]
  end

  # --- find ---

  test 'find returns event by event_id' do
    insert_test_events
    events = ch_select_events(@project.id)
    event_id = events.first['event_id']

    found = Analytics::EventsQueryService.find(@project.id, event_id: event_id)
    assert_not_nil found
    assert_equal event_id, found['event_id']
  end

  test 'find returns nil for nonexistent event_id' do
    found = Analytics::EventsQueryService.find(@project.id, event_id: 'nonexistent')
    assert_nil found
  end

  test 'find returns nil instead of raising when ClickHouse read fails' do
    Clickhouse.stub(:with, -> { raise StandardError, 'clickhouse unavailable' }) do
      assert_nil Analytics::EventsQueryService.find(@project.id, event_id: 'evt_1')
    end
  end

  # --- volume ---

  test 'volume returns bucketed counts' do
    insert_test_events
    result = Analytics::EventsQueryService.volume(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current
    )
    assert result[:buckets].respond_to?(:each), 'buckets should be enumerable'
    assert result[:buckets].size > 0
    result[:buckets].each do |bucket|
      assert bucket['count'] > 0
    end
  end

  test 'volume search filters buckets to matching events' do
    insert_ch_events([
      base_event(event_id: 'volume_purchase', event_name: 'purchase_completed', created_at: '2026-05-05 10:15:00.000'),
      base_event(event_id: 'volume_login', event_name: 'login', created_at: '2026-05-06 10:15:00.000')
    ])

    result = Analytics::EventsQueryService.volume(
      @project.id,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 10),
      search: 'purchase'
    )

    assert_equal 1, result[:buckets].sum { |bucket| bucket['count'].to_i }
    assert result[:buckets].any? { |bucket| bucket['bucket'].to_s.start_with?('2026-05-05') }
  end

  test 'volume returns empty buckets instead of raising when ClickHouse read fails' do
    Clickhouse.stub(:with, -> { raise StandardError, 'clickhouse unavailable' }) do
      result = Analytics::EventsQueryService.volume(
        @project.id,
        start_date: 7.days.ago.to_date,
        end_date: Date.current
      )

      assert_equal({ buckets: [] }, result)
    end
  end

  test 'volume auto-selects hour buckets for short ranges' do
    insert_ch_events([base_event(created_at: '2026-05-01 10:15:00.000')])

    result = Analytics::EventsQueryService.volume(
      @project.id,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 2)
    )

    assert result[:buckets].any? { |bucket| bucket['bucket'].to_s.include?('10:00:00') }
  end

  test 'volume auto-selects day buckets for medium ranges' do
    insert_ch_events([base_event(created_at: '2026-05-05 10:15:00.000')])

    result = Analytics::EventsQueryService.volume(
      @project.id,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 10)
    )

    assert result[:buckets].any? { |bucket| bucket['bucket'].to_s.start_with?('2026-05-05') }
  end

  test 'volume auto-selects week buckets for wide ranges' do
    insert_ch_events([base_event(created_at: '2026-05-20 10:15:00.000')])

    result = Analytics::EventsQueryService.volume(
      @project.id,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 7, 15)
    )

    assert result[:buckets].any? { |bucket| bucket['bucket'].to_s.start_with?('2026-05') }
  end

  test 'volume auto-selects month buckets for long ranges' do
    insert_ch_events([base_event(created_at: '2026-01-15 10:15:00.000')])

    result = Analytics::EventsQueryService.volume(
      @project.id,
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 6, 30)
    )

    assert result[:buckets].any? { |bucket| bucket['bucket'].to_s.start_with?('2026-01') }
  end

  test 'volume falls back to day buckets for invalid explicit bucket' do
    insert_ch_events([base_event(created_at: '2026-05-05 10:15:00.000')])

    result = Analytics::EventsQueryService.volume(
      @project.id,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 10),
      bucket: 'not-a-real-bucket'
    )

    assert result[:buckets].any? { |bucket| bucket['bucket'].to_s.start_with?('2026-05-05') }
  end

  # --- platform normalization ---

  test 'list displays desktop platforms as web' do
    insert_ch_events([
      base_event(event_id: 'plat_mac', platform: 'mac'),
      base_event(event_id: 'plat_win', platform: 'windows'),
      base_event(event_id: 'plat_ios', platform: 'ios')
    ])
    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current
    )
    by_id = result[:data].index_by { |e| e['event_id'] }
    assert_equal 'web', by_id['plat_mac']['platform']
    assert_equal 'web', by_id['plat_win']['platform']
    assert_equal 'ios', by_id['plat_ios']['platform']
  end

  test 'list platform filter web matches desktop rows' do
    insert_ch_events([
      base_event(event_id: 'platf_mac', platform: 'mac'),
      base_event(event_id: 'platf_ios', platform: 'ios')
    ])
    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current,
      filters: [{ 'field' => 'platform', 'operator' => 'is', 'value' => 'web' }]
    )
    ids = result[:data].map { |e| e['event_id'] }
    assert_includes ids, 'platf_mac'
    assert_not_includes ids, 'platf_ios'
  end

  test 'list platform filter mac is normalized to web' do
    insert_ch_events([
      base_event(event_id: 'platn_win', platform: 'windows'),
      base_event(event_id: 'platn_and', platform: 'android')
    ])
    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current,
      filters: [{ 'field' => 'platform', 'operator' => 'is', 'value' => 'mac' }]
    )
    ids = result[:data].map { |e| e['event_id'] }
    assert_includes ids, 'platn_win'
    assert_not_includes ids, 'platn_and'
  end

  test 'find normalizes desktop platform to web' do
    insert_ch_events([base_event(event_id: 'plat_find', platform: 'mac')])
    row = Analytics::EventsQueryService.find(@project.id, event_id: 'plat_find')
    assert_equal 'web', row['platform']
  end

  test 'field_values collapses desktop platforms to web' do
    insert_ch_events([
      base_event(event_id: 'platfv_mac', platform: 'mac'),
      base_event(event_id: 'platfv_ios', platform: 'ios')
    ])
    result = Analytics::EventsQueryService.field_values(@project.id, field: 'platform')
    assert_includes result[:values], 'web'
    assert_includes result[:values], 'ios'
    assert_not_includes result[:values], 'mac'
  end

  # --- field_values ---

  test 'field_values returns distinct platform values' do
    insert_test_events
    result = Analytics::EventsQueryService.field_values(
      @project.id,
      field: 'platform'
    )
    assert_includes result[:values], 'ios'
  end

  test 'field_values with query filters results' do
    insert_test_events
    result = Analytics::EventsQueryService.field_values(
      @project.id,
      field: 'platform',
      q: 'ios'
    )
    assert result[:values].all? { |v| v.downcase.include?('ios') }
  end

  test 'field_values excludes values older than the lookback window' do
    insert_ch_events([
                       { event_id: 'fv_recent', project_id: @project.id, event_type: 'VIEW', platform: 'ios',
                         created_at: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N') },
                       { event_id: 'fv_old', project_id: @project.id, event_type: 'VIEW', platform: 'android',
                         created_at: (@now - 200.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }
                     ])
    result = Analytics::EventsQueryService.field_values(@project.id, field: 'platform')
    assert_includes result[:values], 'ios'
    assert_not_includes result[:values], 'android', 'values older than the lookback window must be excluded'
  end

  test 'field_values honors explicit date range when provided' do
    insert_ch_events([
      base_event(event_id: 'fv_inside_range', platform: 'ios', created_at: '2026-05-05 10:15:00.000'),
      base_event(event_id: 'fv_outside_range', platform: 'android', created_at: '2026-04-20 10:15:00.000')
    ])

    result = Analytics::EventsQueryService.field_values(
      @project.id,
      field: 'platform',
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 31)
    )

    assert_includes result[:values], 'ios'
    assert_not_includes result[:values], 'android'
  end

  test 'field_values returns empty values for invalid field names' do
    insert_ch_events([base_event(platform: 'ios')])

    result = Analytics::EventsQueryService.field_values(@project.id, field: "platform'; DROP TABLE events; --")

    assert_equal({ values: [] }, result)
  end

  test 'field_values returns distinct dynamic property values' do
    insert_ch_events([
      base_event(event_id: 'fv_plan_pro', properties: { 'plan' => 'pro' }),
      base_event(event_id: 'fv_plan_free', properties: { 'plan' => 'free' })
    ])

    result = Analytics::EventsQueryService.field_values(@project.id, field: 'plan')

    assert_equal %w[free pro], result[:values].sort
  end

  test 'field_values paginates distinct values via next_cursor' do
    %w[android ios web].each_with_index do |p, i|
      insert_ch_events([{ event_id: "fv_p#{i}", project_id: @project.id, event_type: 'VIEW', platform: p,
                          created_at: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }])
    end
    page1 = Analytics::EventsQueryService.field_values(@project.id, field: 'platform', limit: 1)
    assert_equal ['android'], page1[:values]
    assert_not_nil page1[:next_cursor]

    page2 = Analytics::EventsQueryService.field_values(@project.id, field: 'platform', limit: 1, cursor: page1[:next_cursor])
    assert_equal ['ios'], page2[:values]
  end

  test 'field_values ignores malformed cursors and returns the first page' do
    %w[android ios].each_with_index do |platform, index|
      insert_ch_events([{ event_id: "fv_bad_cursor_#{index}", project_id: @project.id, event_type: 'VIEW',
                          platform: platform, created_at: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }])
    end

    result = Analytics::EventsQueryService.field_values(
      @project.id,
      field: 'platform',
      limit: 1,
      cursor: 'not-valid-base64!!!'
    )

    assert_equal ['android'], result[:values]
    assert_not_nil result[:next_cursor]
  end

  test 'field_values returns empty values instead of raising when ClickHouse read fails' do
    Clickhouse.stub(:with, -> { raise StandardError, 'clickhouse unavailable' }) do
      assert_equal({ values: [] }, Analytics::EventsQueryService.field_values(@project.id, field: 'platform'))
    end
  end

  test 'fields excludes property keys older than the lookback window' do
    insert_ch_events([
                       { event_id: 'f_recent', project_id: @project.id, event_type: 'VIEW',
                         properties: { 'recent_key' => 'a' },
                         created_at: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N') },
                       { event_id: 'f_old', project_id: @project.id, event_type: 'VIEW',
                         properties: { 'ancient_key' => 'b' },
                         created_at: (@now - 200.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }
                     ])
    names = Analytics::EventsQueryService.fields(@project.id)[:fields].map { |f| f[:name] }
    assert_includes names, 'recent_key'
    assert_not_includes names, 'ancient_key', 'property keys older than the lookback window must be excluded'
  end

  test 'fields offers a property sharing a static field name only once, as the attribute' do
    insert_ch_events([
                       { event_id: 'f_dup', project_id: @project.id, event_type: 'screen_view',
                         properties: { 'screen_name' => 'Home', 'other_key' => 'x' },
                         created_at: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }
                     ])
    fields = Analytics::EventsQueryService.fields(@project.id)[:fields]
    screen_entries = fields.select { |f| f[:name] == 'screen_name' }
    assert_equal [{ name: 'screen_name', type: 'attribute' }], screen_entries
    assert_includes fields, { name: 'other_key', type: 'property' }
  end

  # --- field_values: id-field resolution (resolve_id_field / resolve_visitor_field) ---

  test 'field_values link_id resolves CH ids to PG names' do
    link = links(:basic_link)
    insert_ch_events([base_event(link_id: link.id), base_event(link_id: link.id)])

    result = Analytics::EventsQueryService.field_values(@project.id, field: 'link_id')
    entry = result[:values].find { |v| v[:id] == link.id }
    assert_equal link.name, entry[:name]
  end

  test 'field_values campaign_id with query searches PG names' do
    campaign = campaigns(:one) # "Spring 2026 Campaign", project one
    insert_ch_events([base_event(campaign_id: campaign.id)])

    result = Analytics::EventsQueryService.field_values(@project.id, field: 'campaign_id', q: 'Spring')
    assert_equal [campaign.id], result[:values].map { |v| v[:id] }
  end

  test 'field_values campaign_id with non-matching query returns empty' do
    campaign = campaigns(:one)
    insert_ch_events([base_event(campaign_id: campaign.id)])

    result = Analytics::EventsQueryService.field_values(@project.id, field: 'campaign_id', q: 'zzz-nope')
    assert_empty result[:values]
  end

  test 'field_values visitor_id lists ids without a query' do
    insert_ch_events([base_event(visitor_id: 4242)])
    result = Analytics::EventsQueryService.field_values(@project.id, field: 'visitor_id')
    assert_includes result[:values].map { |v| v[:id] }, 4242
  end

  test 'field_values visitor_id with query does exact match' do
    insert_ch_events([base_event(visitor_id: 4242), base_event(visitor_id: 9999)])
    result = Analytics::EventsQueryService.field_values(@project.id, field: 'visitor_id', q: '4242')
    assert_equal [4242], result[:values].map { |v| v[:id] }
  end

  # --- volume: explicit bucket variants (resolve_bucket) ---

  test 'volume supports week and month buckets' do
    insert_test_events
    %w[week month hour].each do |bucket|
      result = Analytics::EventsQueryService.volume(
        @project.id, start_date: 7.days.ago.to_date, end_date: Date.current, bucket: bucket
      )
      assert result[:buckets].is_a?(Array), "bucket=#{bucket} should return an array"
    end
  end

  # --- fields ---

  test 'fields returns static attributes' do
    result = Analytics::EventsQueryService.fields(@project.id)
    names = result[:fields].map { |f| f[:name] }
    assert_includes names, 'event_type'
    assert_includes names, 'platform'
    assert_includes names, 'screen_name'
  end

  test 'fields discovers dynamic property keys' do
    insert_ch_events([base_event(properties: { 'plan' => 'pro' })])
    result = Analytics::EventsQueryService.fields(@project.id)
    property_fields = result[:fields].select { |f| f[:type] == 'property' }.map { |f| f[:name] }
    assert_includes property_fields, 'plan'
  end

  test 'fields falls back to static attributes when dynamic discovery fails' do
    Clickhouse.stub(:with, -> { raise StandardError, 'clickhouse unavailable' }) do
      names = Analytics::EventsQueryService.fields(@project.id)[:fields].map { |field| field[:name] }

      assert_includes names, 'event_type'
      assert_includes names, 'platform'
      assert_not_includes names, 'plan'
    end
  end

  # Proves the fields cache is keyed by date range. Uses a REAL MemoryStore (the
  # test env default is :null_store, under which Rails.cache.fetch never persists
  # and the cross-range bug is unobservable). With a real store and a single
  # project-only cache key, the Jan call poisons the Jun call for FIELD_CACHE_TTL;
  # keying by range is what keeps each range independent.
  test 'fields cache is keyed by range — two ranges do not poison each other' do
    truncate_clickhouse_tables
    insert_ch_events([
      { project_id: @project.id, event_id: 'old', event_type: 'OPEN',
        created_at: '2026-01-01 00:00:00', properties: { 'old_key' => 'v' } },
      { project_id: @project.id, event_id: 'new', event_type: 'OPEN',
        created_at: '2026-06-01 00:00:00', properties: { 'new_key' => 'v' } }
    ])

    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      jan = Analytics::EventsQueryService.fields(@project.id, start_date: '2026-01-01', end_date: '2026-01-02')
      jun = Analytics::EventsQueryService.fields(@project.id, start_date: '2026-06-01', end_date: '2026-06-02')
      jan_names = jan[:fields].map { |f| f[:name] }
      jun_names = jun[:fields].map { |f| f[:name] }
      assert_includes jan_names, 'old_key'
      assert_not_includes jan_names, 'new_key'
      assert_includes jun_names, 'new_key'
      assert_not_includes jun_names, 'old_key'
    end
  end

  private

  def base_event(**overrides)
    {
      event_id: "evt_#{SecureRandom.hex(6)}",
      project_id: @project.id,
      event_type: 'VIEW',
      created_at: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    }.merge(overrides)
  end

  def insert_test_events(count: 3)
    rows = count.times.map do |i|
      {
        event_id: "test_evt_#{i}_#{SecureRandom.hex(4)}",
        project_id: @project.id,
        event_type: i.even? ? 'VIEW' : 'OPEN',
        event_name: i.even? ? 'home_screen' : 'login_screen',
        screen_name: i.even? ? 'HomeScreen' : 'LoginScreen',
        visitor_id: 1000 + i,
        device_id: 2000 + i,
        platform: 'ios',
        app_version: '1.0.0',
        country: 'US',
        created_at: (@now - i.hours).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
      }
    end
    insert_ch_events(rows)
  end
end
