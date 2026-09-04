# frozen_string_literal: true

# Daily ClickHouse retention deletion, bucketed by delete_days.
class AnalyticsRetentionDeletionJob
  include Sidekiq::Job
  include SingleFlightJob

  sidekiq_options queue: :maintenance, retry: 0

  BACKLOG_THRESHOLD = 50

  def perform
    single_flight!(key: "analytics_retention_deletion", ttl: 30.minutes) do
      backlog = mutation_backlog
      if backlog > BACKLOG_THRESHOLD
        # Retention silently lags when the run skips — make the lag observable so a
        # persistent backlog (retention not being enforced) can be alerted on.
        Grovs::Metrics.increment("clickhouse.retention.skipped", tags: { reason: "backlog" })
        Rails.logger.warn(
          "[AnalyticsRetentionDeletionJob] skipped: mutation backlog #{backlog} > #{BACKLOG_THRESHOLD}"
        )
        next
      end

      delete_buckets.each do |delete_days, project_ids|
        if mutation_backlog > BACKLOG_THRESHOLD
          Grovs::Metrics.increment("clickhouse.retention.skipped", tags: { reason: "backlog_midrun" })
          Rails.logger.warn("[AnalyticsRetentionDeletionJob] stopping mid-run: backlog over #{BACKLOG_THRESHOLD}")
          break
        end

        cutoff = Date.current - delete_days
        errors = ClickhouseDeleteService.delete_projects_before(project_ids, cutoff)
        if errors.empty?
          audit_retention_ran(project_ids, delete_days, cutoff)
          next
        end

        Rails.logger.error(
          "[AnalyticsRetentionDeletionJob] delete_days=#{delete_days} table failures: #{errors.inspect}"
        )
      end
    end
  end

  def delete_buckets
    buckets = Hash.new { |hash, key| hash[key] = [] }
    Instance.includes(:production, :test).find_each(batch_size: 500) do |instance|
      project_ids = [instance.production&.id, instance.test&.id].compact
      next if project_ids.empty?

      buckets[instance.delete_days].concat(project_ids)
    end
    buckets
  end

  # Audit.record is a no-op for unentitled instances: one cheap find_by per instance nightly.
  def audit_retention_ran(project_ids, delete_days, cutoff)
    Project.where(id: project_ids).distinct.pluck(:instance_id).each do |instance_id|
      Audit.record(instance_id: instance_id, action: "retention.deletion_ran", actor: AuditActor.system(self.class.name),
                        target: { "type" => "instance", "id" => instance_id },
                        changes: { "after" => { "cutoff" => cutoff.iso8601, "delete_days" => delete_days } })
    end
  end

  # Scoped to retention tables so an unrelated mutation doesn't skip the run.
  def mutation_backlog
    return 0 unless Clickhouse.enabled?

    tables = ClickhouseDeleteService::RETENTION_DATE_COLUMNS.keys.map { |t| "'#{t}'" }.join(',')
    Clickhouse.with do |conn|
      conn.select_value("SELECT count() FROM system.mutations WHERE is_done = 0 AND table IN (#{tables})")
    end.to_i
  rescue StandardError => e
    Rails.logger.error("[AnalyticsRetentionDeletionJob] backlog probe failed: #{e.message}")
    0
  end
end
