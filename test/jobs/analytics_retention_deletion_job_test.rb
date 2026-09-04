# frozen_string_literal: true

require "test_helper"

class AnalyticsRetentionDeletionJobTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects

  setup do
    instances(:one).update!(delete_days: 730)   # default cohort, 2 projects
    instances(:two).update!(delete_days: 1825)  # custom (enterprise) cohort, 1 project
    @job = AnalyticsRetentionDeletionJob.new
  end

  test "buckets project ids by their instance's delete_days" do
    buckets = @job.delete_buckets

    assert_equal [projects(:one).id, projects(:one_test).id].sort, buckets[730].sort
    assert_equal [projects(:two).id], buckets[1825]
  end

  test "issues one date-bounded delete per distinct delete_days with the right cutoff" do
    calls = []
    @job.stub(:mutation_backlog, 0) do
      ClickhouseDeleteService.stub(:delete_projects_before, lambda { |ids, cutoff| 
        calls << [ids.sort, cutoff]
        []
      }) do
        @job.perform
      end
    end

    assert_includes calls, [[projects(:one).id, projects(:one_test).id].sort, Date.current - 730]
    assert_includes calls, [[projects(:two).id], Date.current - 1825]
    assert_equal 2, calls.size, "exactly one mutation set per distinct delete_days"
  end

  test "skips deletion when the mutation backlog is over the threshold" do
    called = false
    @job.stub(:mutation_backlog, AnalyticsRetentionDeletionJob::BACKLOG_THRESHOLD + 1) do
      ClickhouseDeleteService.stub(:delete_projects_before, lambda { |*| 
        called = true
        []
      }) do
        @job.perform
      end
    end

    assert_not called, "must not pile new mutations on top of an already-high backlog"
  end

  test "emits a skipped metric when the backlog gate trips so the lag is observable" do
    names = []
    @job.stub(:mutation_backlog, AnalyticsRetentionDeletionJob::BACKLOG_THRESHOLD + 1) do
      Grovs::Metrics.stub(:increment, ->(name, **) { names << name }) do
        ClickhouseDeleteService.stub(:delete_projects_before, ->(*) { [] }) { @job.perform }
      end
    end

    assert_includes names, "clickhouse.retention.skipped"
  end

  test "re-checks backlog before each bucket and stops mid-run when it spikes" do
    # preflight ok, first bucket ok, then backlog spikes before the second.
    backlogs = [0, 0, AnalyticsRetentionDeletionJob::BACKLOG_THRESHOLD + 1]
    idx = -1
    calls = []
    @job.stub(:mutation_backlog, lambda { 
      idx += 1
      backlogs[idx] || (AnalyticsRetentionDeletionJob::BACKLOG_THRESHOLD + 1)
    }) do
      ClickhouseDeleteService.stub(:delete_projects_before, lambda { |ids, _cutoff| 
        calls << ids.sort
        []
      }) do
        @job.perform
      end
    end

    assert_equal 1, calls.size, "must stop issuing buckets once backlog spikes mid-run"
  end

  test "is single-flight: a held lock means no work is done" do
    lock_key = "sidekiq:single_flight:analytics_retention_deletion"
    REDIS.with { |c| c.set(lock_key, "another-run", nx: true, ex: 60) }
    called = false

    @job.stub(:mutation_backlog, 0) do
      ClickhouseDeleteService.stub(:delete_projects_before, lambda { |*| 
        called = true
        []
      }) do
        @job.perform
      end
    end

    assert_not called, "a concurrent run holding the lock must not double-issue deletes"
  ensure
    REDIS.with { |c| c.del(lock_key) }
  end

  test "mutation_backlog query is scoped to the retention tables (not DB-wide)" do
    captured = nil
    fake = Object.new
    fake.define_singleton_method(:select_value) do |sql|
      captured = sql
      0
    end
    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:with, ->(&blk) { blk.call(fake) }) do
        @job.mutation_backlog
      end
    end

    assert_includes captured, 'table IN', 'backlog must be scoped, not DB-wide'
    assert_includes captured, "'events'"
    assert_not_includes captured, "'user_profiles'", 'only tables we actually mutate'
  end

  # End-to-end through the real job: no stub on the delete service.
  test "perform actually deletes CH rows older than delete_days end-to-end" do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    instances(:two).update!(delete_days: 730)
    pid = projects(:two).id
    insert_ch_events([
      { project_id: pid, event_type: 'open', created_at: (Date.current - 800).to_time.utc.strftime('%Y-%m-%d %H:%M:%S.%3N') },
      { project_id: pid, event_type: 'open', created_at: (Date.current - 10).to_time.utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }
    ])
    assert_equal 2, ch_event_count(pid)

    AnalyticsRetentionDeletionJob.new.perform
    wait_for_ch_mutations('events')

    assert_equal 1, ch_event_count(pid), "old row deleted, recent kept — via the scheduled job, not a stub"
  end

  private

  def wait_for_ch_mutations(table, timeout: 10)
    deadline = Time.now + timeout
    loop do
      pending = Clickhouse.with do |c|
        c.select_value("SELECT count() FROM system.mutations WHERE table = '#{table}' AND is_done = 0")
      end
      break if pending.to_i.zero?
      raise "CH mutations did not finish for #{table}" if Time.now > deadline

      sleep 0.1
    end
  end
end
