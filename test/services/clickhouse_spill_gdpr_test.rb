# frozen_string_literal: true

require "test_helper"

class ClickhouseSpillGdprTest < ActiveSupport::TestCase
  test "delete_projects removes spill rows for those projects even with CH disabled" do
    prev = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = false

    ClickhouseSpillRepository.store([
      { event_id: "g1", project_id: 42, created_at: "2026-07-01 10:00:00.000" },
      { event_id: "g2", project_id: 43, created_at: "2026-07-01 10:00:00.000" }
    ])

    ClickhouseDeleteService.delete_projects([42])

    assert_nil ClickhouseEventSpill.find_by(event_id: "g1")
    assert ClickhouseEventSpill.find_by(event_id: "g2")
  ensure
    Rails.application.config.clickhouse_write_enabled = prev
  end

  test "delete_projects_before purges old spills even when CH writes are disabled" do
    prev = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = false

    ClickhouseSpillRepository.store([
      { event_id: "rd-old", project_id: 42, created_at: "2026-01-01 10:00:00.000" }
    ])

    ClickhouseDeleteService.delete_projects_before([42], Date.new(2026, 6, 1))

    assert_nil ClickhouseEventSpill.find_by(event_id: "rd-old")
  ensure
    Rails.application.config.clickhouse_write_enabled = prev
  end

  test "reject_tombstoned keeps rows with malformed project_id instead of raising" do
    rows = [
      { project_id: "garbage", event_id: "m1" },
      { project_id: 42, event_id: "m2" },
      { project_id: 7, event_id: "m3" }
    ]

    kept = ClickhouseDeleteService.stub(:tombstoned_project_ids, [42]) do
      ClickhouseDeleteService.reject_tombstoned(rows)
    end

    assert_equal %w[m1 m3], kept.map { |r| r[:event_id] }
  end

  test "delete_projects_before purges spills older than the cutoff, keeps newer ones" do
    prev = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true

    ClickhouseSpillRepository.store([
      { event_id: "r-old", project_id: 42, created_at: "2026-01-01 10:00:00.000" },
      { event_id: "r-new", project_id: 42, created_at: "2026-07-20 10:00:00.000" },
      { event_id: "r-other", project_id: 43, created_at: "2026-01-01 10:00:00.000" }
    ])

    ClickhouseDeleteService.delete_projects_before([42], Date.new(2026, 6, 1))

    assert_nil ClickhouseEventSpill.find_by(event_id: "r-old")
    assert ClickhouseEventSpill.find_by(event_id: "r-new")
    assert ClickhouseEventSpill.find_by(event_id: "r-other")
  ensure
    Rails.application.config.clickhouse_write_enabled = prev
  end
end
