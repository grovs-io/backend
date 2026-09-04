# frozen_string_literal: true

require "test_helper"

class ClickhouseWriteServiceSpillSeamsTest < ActiveSupport::TestCase
  test "prepare_canonical_rows ensures event_id, stamps ingested_at, formats timestamps to strings" do
    rows = [{ project_id: 1, device_id: 2, event_type: "view",
              created_at: Time.zone.parse("2026-07-01 10:00:00.123"),
              event_name: "", session_id: "" }]
    prepared = ClickhouseWriteService.prepare_canonical_rows(rows)

    assert_equal 1, prepared.size
    assert prepared.first[:event_id].present?
    assert_kind_of String, prepared.first[:created_at]
    assert_kind_of String, prepared.first[:ingested_at]
  end

  test "prepare_canonical_rows keeps an existing event_id" do
    rows = [{ project_id: 1, device_id: 2, event_type: "view", event_id: "frozen-id",
              created_at: Time.zone.parse("2026-07-01 10:00:00.123") }]
    assert_equal "frozen-id", ClickhouseWriteService.prepare_canonical_rows(rows).first[:event_id]
  end

  test "insert_prepared_events returns false on CH failure instead of raising or DLQing" do
    raises = proc { raise "ch down" }
    ClickhouseWriteService.stub(:raw_insert, raises) do
      assert_equal false, ClickhouseWriteService.insert_prepared_events([{ project_id: 1 }])
    end
  end

  test "insert_prepared_events returns true for empty rows" do
    assert ClickhouseWriteService.insert_prepared_events([])
  end

  test "insert_spilled raises on CH failure so the drain can record it" do
    raises = proc { raise "still down" }
    ClickhouseWriteService.stub(:raw_insert, raises) do
      assert_raises(RuntimeError) { ClickhouseWriteService.insert_spilled([{ project_id: 1 }]) }
    end
  end

  test "insert_spilled no-ops on empty rows" do
    called = false
    ClickhouseWriteService.stub(:raw_insert, proc { called = true }) do
      ClickhouseWriteService.insert_spilled([])
    end
    assert_not called
  end
end
