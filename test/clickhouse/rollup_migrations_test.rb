# frozen_string_literal: true

require 'test_helper'

class ClickhouseRollupMigrationsTest < ActiveSupport::TestCase
  test 'billing active visitors rollup filters to mapped billing event population' do
    path = Rails.root.join('db/clickhouse/migrate/20260625000006_create_billing_active_visitors_daily.rb')
    sql = File.read(path)

    assert_includes sql, 'CREATE TABLE IF NOT EXISTS billing_active_visitors_daily'
    assert_includes sql, 'visitors_state AggregateFunction(uniqExact, UInt64)'
    assert_includes sql, 'ENGINE = AggregatingMergeTree()'
    assert_includes sql, 'ORDER BY (project_id, event_date)'
    assert_includes sql, 'CREATE MATERIALIZED VIEW IF NOT EXISTS mv_billing_active_visitors_daily'
    assert_includes sql, 'uniqExactState(visitor_id) AS visitors_state'
    assert_includes sql, 'GROUP BY project_id, event_date'
    refute_includes sql, 'GROUP BY project_id, event_date, visitor_id'
    assert_includes sql, 'INSERT INTO billing_active_visitors_daily'
    assert_includes sql, 'WHERE visitor_id != 0'
    assert_includes sql, 'AND event_type IN'
    refute_includes sql, 'ReplacingMergeTree'

    Grovs::Events::MAPPING.keys.each do |event_type|
      assert_includes sql, "'#{event_type}'"
    end

    refute_includes sql, "'#{Grovs::Events::SCREEN_VIEW}'"
    refute_includes sql, "'#{Grovs::Events::CUSTOM}'"
  end

  test 'billing active visitors rollup is included in ClickHouse test cleanup lists' do
    assert_includes ClickhouseTestHelper::PHYSICAL_TABLES, 'billing_active_visitors_daily'
    assert_includes ClickhouseTestHelper::MATERIALIZED_VIEWS, 'mv_billing_active_visitors_daily'
  end

  test 'analytics rollup migrations create version source and property MVs without inline backfills' do
    {
      'project_version_daily' => 'mv_project_version_daily',
      'project_source_daily' => 'mv_project_source_daily',
      'project_property_daily' => 'mv_project_property_daily'
    }.each do |table, mv|
      path = Dir[Rails.root.join("db/clickhouse/migrate/*create_#{table}.rb")].first
      sql = File.read(path)

      assert_includes sql, "CREATE TABLE IF NOT EXISTS #{table}"
      assert_includes sql, "CREATE MATERIALIZED VIEW IF NOT EXISTS #{mv}"
      refute_includes sql, "INSERT INTO #{table}"
      assert_includes ClickhouseTestHelper::PHYSICAL_TABLES, table
      assert_includes ClickhouseTestHelper::MATERIALIZED_VIEWS, mv
    end
  end

  test 'property rollup migration is deliberately allowlisted' do
    sql = File.read(Rails.root.join('db/clickhouse/migrate/20260625000009_create_project_property_daily.rb'))

    assert_includes sql, "tuple('plan', JSONExtractString(properties, 'plan'))"
    assert_includes sql, "tuple('tier', JSONExtractString(properties, 'tier'))"
    assert_includes sql, "WHERE property_value != ''"
    refute_includes sql, 'JSONAllPaths'
  end

  test 'purchase project daily rebuild is correction safe' do
    sql = File.read(Rails.root.join('db/clickhouse/migrate/20260625000010_rebuild_purchase_project_daily_as_replacing_facts.rb'))

    assert_includes sql, 'DROP TABLE IF EXISTS mv_purchase_project_daily'
    assert_includes sql, 'ENGINE = ReplacingMergeTree(created_at)'
    assert_includes sql, 'transaction_id'
    assert_includes sql, 'FROM purchase_events FINAL'
    refute_includes sql, 'AggregatingMergeTree'
    refute_includes sql, 'uniqState(visitor_id)'
  end
end
