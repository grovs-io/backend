# frozen_string_literal: true

require "test_helper"

class ClickhouseSpillRepositoryTest < ActiveSupport::TestCase
  def prepared_row(event_id: "e1", project_id: 5)
    { event_id: event_id, project_id: project_id, device_id: 9, event_type: "view",
      created_at: "2026-07-01 10:00:00.123", ingested_at: "2026-07-01 10:00:01.000" }
  end

  test "store inserts one spill row per ch row with metadata extracted" do
    assert_difference "ClickhouseEventSpill.count", 1 do
      ClickhouseSpillRepository.store([prepared_row])
    end
    spill = ClickhouseEventSpill.find_by!(event_id: "e1")
    assert_equal 5, spill.project_id
    assert_equal Time.zone.parse("2026-07-01 10:00:00.123"), spill.event_created_at
    assert_equal "view", spill.ch_row["event_type"]
    assert_equal 0, spill.attempts
    assert spill.spilled_at.present?
  end

  test "store is idempotent on event_id" do
    ClickhouseSpillRepository.store([prepared_row])
    assert_no_difference "ClickhouseEventSpill.count" do
      ClickhouseSpillRepository.store([prepared_row])
    end
  end

  test "store of empty array is a no-op" do
    assert_no_difference "ClickhouseEventSpill.count" do
      ClickhouseSpillRepository.store([])
    end
  end

  test "store falls back to now for an unparseable created_at" do
    row = prepared_row(event_id: "e-bad").merge(created_at: "not-a-time")
    ClickhouseSpillRepository.store([row])
    assert_in_delta Time.current.to_f, ClickhouseEventSpill.find_by!(event_id: "e-bad").event_created_at.to_f, 5
  end

  test "drainable scope skips rows at max attempts and orders oldest first" do
    ClickhouseSpillRepository.store([prepared_row(event_id: "a"), prepared_row(event_id: "b")])
    ClickhouseEventSpill.find_by!(event_id: "a").update!(attempts: ClickhouseEventSpill::MAX_DRAIN_ATTEMPTS)
    assert_equal ["b"], ClickhouseEventSpill.drainable.pluck(:event_id)
  end
end
