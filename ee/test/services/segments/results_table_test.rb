require "test_helper"

class SegmentsResultsTableTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  setup do
    skip_unless_clickhouse!
    @__clickhouse_test_started = true
  end

  test "segment_results accepts rows and is wiped with the project" do
    Clickhouse.with do |c|
      c.insert("segment_results", [{ project_id: 9_301, result_id: "a" * 32, visitor_id: 1, eff_visitor_id: 1, person_key: "v:1" }])
    end
    assert_equal 1, Clickhouse.with { |c| c.select_value("SELECT count() FROM segment_results WHERE project_id = 9301") }.to_i
    assert_includes ClickhouseDeleteService::PROJECT_TABLES, "segment_results"
    assert_includes ClickhouseDeleteService::RETENTION_EXEMPT, "segment_results"
  end

  test "rows expire by TTL three hours after creation" do
    ddl = Clickhouse.with { |c| c.select_value("SHOW CREATE TABLE segment_results") }
    assert_match(/TTL .*toIntervalHour\(3\)|INTERVAL 3 HOUR/i, ddl)
  end
end
