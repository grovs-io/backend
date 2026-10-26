# frozen_string_literal: true

require 'test_helper'

class Analytics::EventsSourceTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  test 'both branches project every events column in DDL order' do
    sql = Analytics::EventsSource.sql(final: false, project_id: 1)
    events_branch, purchase_branch = sql.split('UNION ALL')
    Analytics::EventsSource::COLUMNS.each do |col|
      assert_match(/\b#{col}\b/, events_branch)
      assert_match(/ AS #{col}\b/, purchase_branch)
    end
    assert_no_match(/FROM events FINAL/, sql)
    assert_match(/FROM events FINAL/, Analytics::EventsSource.sql(final: true, project_id: 1))
  end

  test 'the purchase branch is project-scoped and dedups with LIMIT BY, never FINAL' do
    sql = Analytics::EventsSource.sql(final: true, project_id: 42, start_sql: '2026-09-01 00:00:00.000')
    purchase_branch = sql.split('UNION ALL').last
    assert_includes purchase_branch, 'p.project_id = 42'
    assert_includes purchase_branch, "p.created_at >= toDateTime64('2026-09-01 00:00:00.000', 3, 'UTC')"
    assert_includes purchase_branch, 'LIMIT 1 BY p.project_id, p.transaction_id, p.event_type'
    assert_no_match(/purchase_events AS p FINAL/, purchase_branch)
    assert_includes sql, 'UNION ALL SELECT * FROM (SELECT'
    assert_not_includes Analytics::EventsSource.sql(final: false, project_id: 42), 'p.created_at >='
  end

  test 'event_id lands inside the purchase branch, before the sort' do
    purchase_branch = Analytics::EventsSource.purchase_sql(project_id: 7, event_id: 'abc123')
    predicate = "lower(hex(MD5(concat('purchase:', p.transaction_id, ':', p.event_type)))) = 'abc123'"
    assert_operator purchase_branch.index(predicate), :<, purchase_branch.index('ORDER BY p.created_at DESC')
  end

  test 'COLUMNS matches the live events table exactly, in order' do
    skip_unless_clickhouse!
    live = Clickhouse.with do |c|
      c.select_all("SELECT name FROM system.columns WHERE database = currentDatabase() AND table = 'events' " \
                   'ORDER BY position').to_a.map { |r| r['name'] }
    end
    assert_equal live, Analytics::EventsSource::COLUMNS
  end

  test 'purchase ids are url-safe and match the SQL expression' do
    skip_unless_clickhouse!
    ruby_id = Analytics::EventsSource.purchase_event_id('GPA.3312-1234.5678', 'buy')
    ch_id = Clickhouse.with do |c|
      c.select_value("SELECT lower(hex(MD5(concat('purchase:', 'GPA.3312-1234.5678', ':', 'buy'))))")
    end
    assert_equal ch_id, ruby_id
    assert_match(/\A[0-9a-f]{32}\z/, ruby_id)
  end

  test 'the union executes against ClickHouse with every column typed and collapses versions' do
    skip_unless_clickhouse!
    now = Time.current.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    later = (Time.current + 40.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') # next partition on purpose
    insert_ch_events([{ project_id: 1, event_type: 'view', created_at: now, visitor_id: 7 }])
    Clickhouse.with do |c|
      c.insert('purchase_events', [
        { project_id: 1, event_type: 'buy', transaction_id: 't1', visitor_id: 7, product_id: 'old',
          purchase_date: now, recorded_at: now, created_at: now },
        { project_id: 1, event_type: 'buy', transaction_id: 't1', visitor_id: 7, product_id: 'new',
          purchase_date: now, recorded_at: now, created_at: later }
      ])
    end

    src = Analytics::EventsSource.sql(final: false, project_id: 1)
    rows = Clickhouse.with { |c| c.select_all("SELECT event_type, properties FROM #{src} ORDER BY event_type").to_a }
    assert_equal %w[purchase view], rows.map { |r| r['event_type'] }
    assert_equal 'new', rows.first['properties']['purchase']['product_id']
    types = Clickhouse.with do |c|
      c.select_all("SELECT DISTINCT toTypeName(properties) AS p, toTypeName(sdk_attributes) AS s FROM #{src}").to_a
    end
    assert_equal [%w[JSON JSON]], types.map { |t| t.values_at('p', 's') }
  end
end
