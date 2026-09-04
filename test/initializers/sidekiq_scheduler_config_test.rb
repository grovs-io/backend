# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

class SidekiqSchedulerConfigTest < ActiveSupport::TestCase
  test "session build job is scheduled on a serviced queue" do
    schedule = scheduler_config.fetch(:scheduler).fetch("schedule")
    entry = schedule.values.find { |config| config.fetch("class") == "SessionBuildJob" }

    assert_not_nil entry, "SessionBuildJob must be scheduled or sessions analytics will go stale"
    assert_equal "maintenance", entry.fetch("queue")
    assert_includes serviced_maintenance_queues, entry.fetch("queue")
    cron = Fugit::Cron.parse(entry.fetch("cron"))
    assert_not_nil cron, "cron must be a valid expression"
    # Sessions freshness is the interval plus a ~25s pass; the smoke test allows 6 min end to end.
    assert_equal 2.minutes, interval_seconds(cron), "session build must run every 2 minutes"
  end

  test "analytics retention deletion is scheduled: resolvable Sidekiq job, valid cron, serviced queue" do
    schedule = scheduler_config.fetch(:scheduler).fetch("schedule")
    entry = schedule.values.find { |config| config.fetch("class") == "AnalyticsRetentionDeletionJob" }

    assert_not_nil entry, "AnalyticsRetentionDeletionJob must be scheduled or retention never runs"
    assert_includes serviced_maintenance_queues, entry.fetch("queue")

    klass = entry.fetch("class").constantize
    assert klass.include?(Sidekiq::Job), "scheduled class must be a real Sidekiq job"
    assert_not_nil Fugit::Cron.parse(entry.fetch("cron")), "cron must be a valid expression"
  end

  test "rollup catch-up lane is scheduled with the catchup arg on a serviced queue" do
    schedule = scheduler_config.fetch(:scheduler).fetch("schedule")
    entry = schedule.values.find do |config|
      config.fetch("class") == "RebuildClickhouseRollupsJob" &&
        config["args"] == [RebuildClickhouseRollupsJob::CATCHUP_SCOPE]
    end

    assert_not_nil entry, "catch-up lane must be scheduled or out-of-window dirty partitions never rebuild"
    assert_includes serviced_maintenance_queues, entry.fetch("queue")
    assert_not_nil Fugit::Cron.parse(entry.fetch("cron")), "cron must be a valid expression"
  end

  # It left BackfillLast3DaysJob's 10-min piggyback; without its own entry it never runs.
  test "enterprise MAU precompute is scheduled on a serviced queue, less often than every 10 minutes" do
    schedule = scheduler_config.fetch(:scheduler).fetch("schedule")
    entry = schedule.values.find { |config| config.fetch("class") == "PrecomputeEnterpriseMausJob" }

    assert_not_nil entry, "PrecomputeEnterpriseMausJob must be scheduled or enterprise usage goes stale"
    assert_includes serviced_maintenance_queues, entry.fetch("queue")

    cron = Fugit::Cron.parse(entry.fetch("cron"))
    assert_not_nil cron, "cron must be a valid expression"
    assert_operator interval_seconds(cron), :>, 10.minutes, "the point of the split was a longer interval"
  end

  # Each pass is an uncached exact MAU read per instance; the upper bound is what Stripe bills.
  test "the quota pass runs every 30 minutes" do
    schedule = scheduler_config.fetch(:scheduler).fetch("schedule")
    entry = schedule.values.find { |config| config.fetch("class") == "DisableQuotasJob" }

    assert_not_nil entry, "quota enforcement must be scheduled"
    interval = interval_seconds(Fugit::Cron.parse(entry.fetch("cron")))
    assert_operator interval, :>, 10.minutes, "exact MAU reads are too costly to repeat every 10 minutes"
    assert_operator interval, :<=, 30.minutes, "Stripe has no invoice-time re-push; this bounds the undercount"
  end

  private

  def interval_seconds(cron)
    from = Time.utc(2026, 1, 1)
    cron.next_time(cron.next_time(from).to_t).to_i - cron.next_time(from).to_i
  end

  def scheduler_config
    YAML.safe_load(
      ERB.new(Rails.root.join("config/sidekiq_scheduler.yml").read).result,
      permitted_classes: [Symbol],
      aliases: true
    )
  end

  def serviced_maintenance_queues
    config = YAML.safe_load(
      ERB.new(Rails.root.join("config/sidekiq_maintenance.yml").read).result,
      permitted_classes: [Symbol],
      aliases: true
    )

    config.fetch(:queues).map { |queue| Array(queue).first }
  end
end
