# frozen_string_literal: true

require "test_helper"

# CI-safe: stubs ClickHouse entirely, so it runs without a live server.
class ClickhouseWriteServiceMetricTest < ActiveSupport::TestCase
  test "a failed write emits clickhouse.write.failed tagged by table, counting rows" do
    captured = []
    Grovs::Metrics.stub(:increment, ->(name, by: 1, tags: {}) { captured << { name: name, by: by, tags: tags } }) do
      Clickhouse.stub(:enabled?, true) do
        Clickhouse.stub(:with, ->(*) { raise "ch unreachable" }) do
          result = ClickhouseWriteService.insert_canonical_events([{ project_id: 1 }, { project_id: 2 }])
          assert_equal false, result
        end
      end
    end

    metric = captured.find { |c| c[:name] == "clickhouse.write.failed" }
    assert metric, "expected clickhouse.write.failed metric on write failure"
    assert_equal 2, metric[:by], "counts the rows that were not written"
    assert_equal({ table: "events" }, metric[:tags])
  end

  test "a no-op write (CH disabled) emits no failure metric" do
    captured = []
    Grovs::Metrics.stub(:increment, ->(*args, **_kw) { captured << args }) do
      Clickhouse.stub(:enabled?, false) do
        assert_equal true, ClickhouseWriteService.insert_canonical_events([{ project_id: 1 }])
      end
    end
    assert_empty captured
  end
end
