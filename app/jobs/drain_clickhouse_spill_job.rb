# frozen_string_literal: true

# Replays clickhouse_event_spills into CH; idempotent (RMT dedups on event_id).
class DrainClickhouseSpillJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: false

  BATCH_SIZE = 500
  TIME_BUDGET_SECONDS = 50
  LOCK_KEY = "clickhouse:spill:drain_lock"

  def perform
    return unless Clickhouse.enabled?
    return unless ClickhouseEventSpill.exists?
    return unless acquire_lock

    begin
      drain
    ensure
      release_lock
    end
  end

  private

  def drain
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIME_BUDGET_SECONDS
    drained = 0
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      batch = ClickhouseEventSpill.drainable.limit(BATCH_SIZE).to_a
      break if batch.empty?

      rows = replayable_rows(batch)
      begin
        ClickhouseWriteService.insert_spilled(rows)
      rescue StandardError => e
        # Outage must not consume attempts; only poison rows do, isolated per row.
        if ch_reachable?
          drained += drain_individually(batch, kept_ids: rows.map { |r| r[:event_id] }.to_set, deadline: deadline)
        end
        Rails.logger.warn("DrainClickhouseSpillJob: batch insert failed (#{e.class}: #{e.message})")
        break
      end
      # mark_dirty before delete so a crash re-drains instead of staling rollups
      rows.each { |r| ClickhouseRollupRebuildService.mark_dirty(r[:created_at].to_date) }
      bust_mau_caches(rows)
      ClickhouseEventSpill.where(id: batch.map(&:id)).delete_all
      drained += rows.size
    end

    report_exhausted_rows
    return unless drained.positive?

    Grovs::Metrics.increment("clickhouse.spill.drained", by: drained)
    Rails.logger.info("DrainClickhouseSpillJob drained #{drained} events")
  end

  def replayable_rows(batch)
    rows = batch.map { |s| s.ch_row.symbolize_keys }
    kept = reject_deleted_projects(ClickhouseDeleteService.reject_tombstoned(rows))
    discarded = rows.size - kept.size
    Grovs::Metrics.increment("clickhouse.spill.discarded_tombstoned", by: discarded) if discarded.positive?
    kept
  end

  # A settled month cached during the outage would miss the recovered events for 30 days.
  def bust_mau_caches(rows)
    rows.group_by { |r| r[:project_id] }.each do |project_id, project_rows|
      partitions = project_rows.map { |r| r[:created_at].to_date.strftime("%Y%m") }.uniq
      ProjectService.bust_mau_cache(project_id, partitions)
    end
  end

  # Durable GDPR barrier: covers spills for erased projects even if the Redis tombstone failed.
  def reject_deleted_projects(rows)
    return rows if rows.empty?

    live = Project.where(id: rows.map { |r| r[:project_id].to_i }.uniq).pluck(:id).to_set
    rows.select { |r| live.include?(r[:project_id].to_i) }
  end

  def acquire_lock
    REDIS.with { |conn| conn.set(LOCK_KEY, jid.to_s, nx: true, ex: TIME_BUDGET_SECONDS + 10) }
  end

  def release_lock
    REDIS.with { |conn| conn.del(LOCK_KEY) }
  rescue Redis::BaseError => e
    Rails.logger.warn("DrainClickhouseSpillJob: lock release failed (#{e.class}); expires via TTL")
  end

  # Per-row poison isolation: only genuinely rejected rows accrue attempts.
  def drain_individually(batch, kept_ids:, deadline:)
    drained = 0
    batch.each do |spill|
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      row = spill.ch_row.symbolize_keys
      unless kept_ids.include?(row[:event_id])
        spill.delete
        next
      end
      begin
        ClickhouseWriteService.insert_spilled([row])
        ClickhouseRollupRebuildService.mark_dirty(row[:created_at].to_date)
        bust_mau_caches([row])
        spill.delete
        drained += 1
      rescue StandardError => e
        if overload_error?(e)
          Rails.logger.warn("DrainClickhouseSpillJob: overload during isolation (#{e.class}); stopping until next run")
          break
        end
        spill.update_columns(attempts: spill.attempts + 1, last_error: e.message.to_s.first(500))
      end
    end
    drained
  end

  def overload_error?(error)
    return true if error.is_a?(Net::OpenTimeout) || error.is_a?(Net::ReadTimeout) ||
                   error.is_a?(Timeout::Error) || error.is_a?(Errno::ECONNREFUSED) ||
                   error.is_a?(Errno::ECONNRESET)

    error.message.to_s.match?(/timeout|timed out|TOO_MANY_SIMULTANEOUS_QUERIES|MEMORY_LIMIT_EXCEEDED/i)
  end

  def ch_reachable?
    Clickhouse.with { |conn| conn.select_value("SELECT 1") }
    true
  rescue StandardError
    false
  end

  def report_exhausted_rows
    exhausted = ClickhouseEventSpill.where("attempts >= ?", ClickhouseEventSpill::MAX_DRAIN_ATTEMPTS).count
    return unless exhausted.positive?

    Grovs::Metrics.histogram("clickhouse.spill.exhausted", exhausted)
    Rails.logger.error("DrainClickhouseSpillJob: #{exhausted} spill rows exhausted retries — manual inspection needed")
  end
end
