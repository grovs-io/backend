# frozen_string_literal: true

require "test_helper"

class DrainClickhouseSpillJobTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects

  setup do
    @project = projects(:one)
    @original_ch_enabled = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true
    REDIS.with { |conn| conn.del(DrainClickhouseSpillJob::LOCK_KEY) }
  end

  teardown do
    Rails.application.config.clickhouse_write_enabled = @original_ch_enabled
    REDIS.with { |conn| conn.del(DrainClickhouseSpillJob::LOCK_KEY) }
  end

  def spill!(event_id:, project_id: @project.id, created_at: "2026-07-01 10:00:00.123")
    row = { event_id: event_id, project_id: project_id, device_id: 9, visitor_id: 3,
            event_type: "view", created_at: created_at, ingested_at: created_at }
    ClickhouseSpillRepository.store([row])
    ClickhouseEventSpill.find_by!(event_id: event_id)
  end

  test "drains spill rows into CH and deletes them" do
    skip_unless_clickhouse!
    spill!(event_id: "d1")

    DrainClickhouseSpillJob.new.perform

    assert_equal 0, ClickhouseEventSpill.count
    assert_equal 1, ch_event_count(@project.id)
  end

  test "delivered rows bust the MAU cache for their (project, month)" do
    skip_unless_clickhouse!
    spill!(event_id: "b1", created_at: "2026-05-03 10:00:00.123")
    spill!(event_id: "b2", created_at: "2026-05-20 10:00:00.123")
    busted = []

    ProjectService.stub(:bust_mau_cache, ->(pid, partitions) { busted << [pid, partitions.sort] }) do
      DrainClickhouseSpillJob.new.perform
    end

    assert_equal [[@project.id, %w[202605]]], busted, "a settled cached month must recompute after recovery"
  end

  test "skips entirely when another drain holds the lock" do
    spill!(event_id: "lk1")
    REDIS.with { |conn| conn.set(DrainClickhouseSpillJob::LOCK_KEY, "other-jid", ex: 60) }

    called = false
    ClickhouseWriteService.stub(:raw_insert, proc { called = true }) do
      DrainClickhouseSpillJob.new.perform
    end

    assert_not called
    assert_equal 1, ClickhouseEventSpill.count
    assert_equal "other-jid", REDIS.with { |conn| conn.get(DrainClickhouseSpillJob::LOCK_KEY) }
  end

  test "rows for deleted projects are discarded, not drained" do
    spill!(event_id: "dp1", project_id: 999_777_666)
    inserted = []

    ClickhouseWriteService.stub(:raw_insert, proc { |*a| inserted << a }) do
      DrainClickhouseSpillJob.new.perform
    end

    assert_empty inserted
    assert_equal 0, ClickhouseEventSpill.count
  end

  test "poison row (CH reachable, insert rejected) bumps attempts, records error, stops the run" do
    spill!(event_id: "d2")
    job = DrainClickhouseSpillJob.new

    job.stub(:ch_reachable?, true) do
      ClickhouseWriteService.stub(:raw_insert, proc { raise "bad row" }) do
        job.perform
      end
    end

    spill = ClickhouseEventSpill.find_by!(event_id: "d2")
    assert_equal 1, spill.attempts
    assert_match "bad row", spill.last_error
  end

  test "outage (CH unreachable) does NOT consume attempts — healthy rows never strand" do
    spill!(event_id: "d2b")
    job = DrainClickhouseSpillJob.new

    job.stub(:ch_reachable?, false) do
      ClickhouseWriteService.stub(:raw_insert, proc { raise "connection refused" }) do
        11.times { job.perform }
      end
    end

    spill = ClickhouseEventSpill.find_by!(event_id: "d2b")
    assert_equal 0, spill.attempts
    assert_equal 1, ClickhouseEventSpill.drainable.count
  end

  test "poison batch isolates per row: healthy rows drain, only the bad row accrues attempts" do
    spill!(event_id: "healthy-1")
    spill!(event_id: "poison")
    spill!(event_id: "healthy-2")
    job = DrainClickhouseSpillJob.new

    selective = proc do |_table, rows|
      raise "row rejected" if rows.any? { |r| r[:event_id] == "poison" }
    end

    job.stub(:ch_reachable?, true) do
      ClickhouseWriteService.stub(:raw_insert, selective) do
        job.perform
      end
    end

    assert_nil ClickhouseEventSpill.find_by(event_id: "healthy-1")
    assert_nil ClickhouseEventSpill.find_by(event_id: "healthy-2")
    poison = ClickhouseEventSpill.find_by!(event_id: "poison")
    assert_equal 1, poison.attempts
    assert_match "row rejected", poison.last_error
  end

  test "tombstoned rows are deleted without insert and not counted as drained" do
    spill!(event_id: "t1", project_id: 999_888)
    inserted = []
    keep_none = proc { |_rows| [] }

    ClickhouseDeleteService.stub(:reject_tombstoned, keep_none) do
      ClickhouseWriteService.stub(:raw_insert, proc { |*a| inserted << a }) do
        DrainClickhouseSpillJob.new.perform
      end
    end

    assert_empty inserted
    assert_equal 0, ClickhouseEventSpill.count
  end

  test "isolation stops on overload-shaped errors without consuming attempts" do
    spill!(event_id: "ov-1")
    spill!(event_id: "ov-2")
    job = DrainClickhouseSpillJob.new

    job.stub(:ch_reachable?, true) do
      ClickhouseWriteService.stub(:raw_insert, proc { raise Net::ReadTimeout }) do
        job.perform
      end
    end

    assert_equal [0, 0], ClickhouseEventSpill.order(:event_id).pluck(:attempts)
    assert_equal 2, ClickhouseEventSpill.drainable.count
  end

  test "isolation respects the job deadline" do
    spill!(event_id: "dl-1")
    spill!(event_id: "dl-2")
    job = DrainClickhouseSpillJob.new
    batch = ClickhouseEventSpill.drainable.to_a

    calls = 0
    counting = proc { |*| calls += 1 }
    ClickhouseWriteService.stub(:raw_insert, counting) do
      past = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
      drained = job.send(:drain_individually, batch, kept_ids: %w[dl-1 dl-2].to_set, deadline: past)
      assert_equal 0, drained
    end

    assert_equal 0, calls
    assert_equal 2, ClickhouseEventSpill.count
  end

  test "rows at max attempts are skipped entirely" do
    spill = spill!(event_id: "d3")
    spill.update!(attempts: ClickhouseEventSpill::MAX_DRAIN_ATTEMPTS)

    called = false
    ClickhouseWriteService.stub(:raw_insert, proc { called = true }) do
      DrainClickhouseSpillJob.new.perform
    end

    assert_not called
    assert_equal ClickhouseEventSpill::MAX_DRAIN_ATTEMPTS, spill.reload.attempts
  end

  test "no-ops instantly when spill is empty" do
    called = false
    ClickhouseWriteService.stub(:raw_insert, proc { called = true }) do
      DrainClickhouseSpillJob.new.perform
    end
    assert_not called
  end

  test "no-ops when clickhouse writes are disabled" do
    Rails.application.config.clickhouse_write_enabled = false
    spill!(event_id: "d4")

    DrainClickhouseSpillJob.new.perform

    assert_equal 1, ClickhouseEventSpill.count
  end

  test "second drain run after success is idempotent in CH" do
    skip_unless_clickhouse!
    spill!(event_id: "d5")
    DrainClickhouseSpillJob.new.perform

    spill!(event_id: "d5")
    DrainClickhouseSpillJob.new.perform

    assert_equal 1, ch_event_count(@project.id)
    assert_equal 0, ClickhouseEventSpill.count
  end
end
