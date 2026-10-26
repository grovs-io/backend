require "test_helper"

class SegmentsIdentifierEntriesTableTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  setup do
    skip_unless_clickhouse!
    @__clickhouse_test_started = true
  end

  test "entries are stored per generation and wiped with the project" do
    Clickhouse.with { |c| c.insert("segment_identifier_entries", [{ project_id: 9_401, segment_id: 5, generation: "g1", identifier: "a@x.io" }]) }
    n = Clickhouse.with { |c| c.select_value("SELECT count() FROM segment_identifier_entries WHERE project_id = 9401 AND generation = 'g1'") }
    assert_equal 1, n.to_i
    assert_includes ClickhouseDeleteService::PROJECT_TABLES, "segment_identifier_entries"
    assert_includes ClickhouseDeleteService::RETENTION_EXEMPT, "segment_identifier_entries"
  end
end
