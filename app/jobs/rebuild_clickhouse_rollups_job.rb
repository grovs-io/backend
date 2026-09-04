class RebuildClickhouseRollupsJob < ApplicationJob
  include SingleFlightJob

  queue_as :maintenance

  CURRENT_MONTH_SCOPE = "current_month"
  CATCHUP_SCOPE = "catchup"
  LANES = { CURRENT_MONTH_SCOPE => "fast", CATCHUP_SCOPE => "catchup" }.freeze
  # Bounds the nightly pass: a merge-driven backlog can span years of partitions.
  CATCHUP_TTL = 4.hours
  # Under CH pressure a pass can outlive the 10-min cadence; late copies must skip, not stack.
  FULL_TTL = 30.minutes

  def perform(scope = "full")
    case scope
    when CURRENT_MONTH_SCOPE
      # Env-gated every-minute current-partition rebuild; the heavy watermark pass is untouched.
      return unless ClickhouseRollupRebuildService.fast_lane_enabled?

      partition = ClickhouseRollupRebuildService.partition_for(Date.current)
      # strict: without it a rollup failure never reaches the rescue and never alerts.
      ClickhouseRollupRebuildService.rebuild_partition_range(
        partition, partition,
        rollups: ClickhouseRollupRebuildService::ROLLUPS.keys + [:acquisition],
        strict: true
      )
      ClickhouseRollupLiveness.record(:fast)
    when CATCHUP_SCOPE
      # Daily absorption of dirty partitions older than the watermark window.
      single_flight!(key: "rollup_catchup", ttl: CATCHUP_TTL) do |deadline|
        ClickhouseRollupRebuildService.rebuild_stale_dirty(deadline: deadline)
      end
    else
      # Dirty-tracking is best-effort; the watermark window is the real convergence guarantee.
      single_flight!(key: "rollup_full", ttl: FULL_TTL) do
        # Stamps :full itself and withholds it when a partition failed — never stamp here too.
        ClickhouseRollupRebuildService.rebuild_all_dirty
      end
    end
  rescue StandardError => e
    # Never raises — the rollups are only refreshed here, so a silent failure freezes them.
    Grovs::Metrics.increment("clickhouse.rollup_rebuild.failed",
      tags: { lane: LANES.fetch(scope, "full") })
    Rails.logger.error("RebuildClickhouseRollupsJob: rebuild failed: #{e.class} - #{e.message}")
  end
end
