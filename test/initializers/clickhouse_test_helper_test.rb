# frozen_string_literal: true

require "test_helper"

class ClickhouseTestHelperTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  test "skip_unless_clickhouse skips when ClickHouse is optional and unavailable" do
    with_clickhouse_required(nil) do
      ClickhouseTestHelper.stub(:available?, false) do
        assert_raises(Minitest::Skip) { skip_unless_clickhouse! }
      end
    end
  end

  test "skip_unless_clickhouse fails when ClickHouse is required and unavailable" do
    with_clickhouse_required("true") do
      ClickhouseTestHelper.stub(:available?, false) do
        error = assert_raises(Minitest::Assertion) { skip_unless_clickhouse! }
        assert_match(/required/, error.message)
      end
    end
  end

  test "ensure_tables recreates schema when cache is warm but required tables are missing" do
    skip_unless_clickhouse!

    ClickhouseTestHelper.ensure_tables!
    Clickhouse.with { |conn| conn.execute("DROP TABLE IF EXISTS `events`") }
    ClickhouseTestHelper.instance_variable_set(:@tables_created_by_database, {
      Clickhouse.default_database => true
    })

    ClickhouseTestHelper.ensure_tables!

    assert_includes clickhouse_tables, "events"
  ensure
    if ClickhouseTestHelper.available?
      ClickhouseTestHelper.instance_variable_set(:@tables_created_by_database, {})
      ClickhouseTestHelper.ensure_tables!
    end
  end

  # No skip_unless_clickhouse! here on purpose — that is the unpinned case setup must cover.
  test "a test method that never calls skip_unless_clickhouse still sees this class's database" do
    skip "ClickHouse unavailable" unless ClickhouseTestHelper.available?

    assert_includes Clickhouse.default_database, "clickhouse_test_helper_test"
  end

  test "isolated database is stable for repeated setup calls in the same test class" do
    skip_unless_clickhouse!

    first_database = Clickhouse.default_database
    truncate_clickhouse_tables
    second_database = Clickhouse.default_database

    assert_equal first_database, second_database
    assert_includes second_database, "clickhouse_test_helper_test"
    refute_includes second_database, "clickhouse_test_helper_test_clickhouse_test_helper_test"
  end

  test "truncate_clickhouse_tables clears rows within the class isolated database" do
    skip_unless_clickhouse!

    insert_ch_events(
      project_id: 12345,
      event_type: "cleanup_probe",
      created_at: Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%3N")
    )
    assert_equal 1, ch_event_count(12345, event_type: "cleanup_probe")

    truncate_clickhouse_tables

    assert_equal 0, ch_event_count(12345, event_type: "cleanup_probe")
  end

  test "skip_unless_clickhouse records that the test used ClickHouse" do
    skip_unless_clickhouse!

    assert_equal true, instance_variable_get(:@__clickhouse_test_started)
  end

  private

  def with_clickhouse_required(value)
    old_value = ENV["CLICKHOUSE_REQUIRED"]
    value.nil? ? ENV.delete("CLICKHOUSE_REQUIRED") : ENV["CLICKHOUSE_REQUIRED"] = value
    yield
  ensure
    old_value.nil? ? ENV.delete("CLICKHOUSE_REQUIRED") : ENV["CLICKHOUSE_REQUIRED"] = old_value
  end

  def clickhouse_tables
    Clickhouse.with do |conn|
      conn.select_all("SELECT name FROM system.tables WHERE database = currentDatabase()").map { |row| row["name"] }
    end
  end
end
