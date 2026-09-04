# frozen_string_literal: true

module ClickhouseDeleteService
  # All CH tables that store project-scoped data, including MV target tables.
  # MV targets require explicit DELETE — they are NOT auto-cleared when source rows are deleted.
  PROJECT_TABLES = %w[
    events
    purchase_events
    user_profiles
    project_daily
    link_daily
    visitor_daily
    project_country_daily
    project_version_daily
    project_source_daily
    project_property_daily
    billing_active_visitors_daily
    purchase_project_daily
    purchase_product_daily
    session_events
    session_summary
    project_metrics_daily
    link_metrics_daily
    link_session_daily
    visitor_metrics_daily
    visitor_dimension_daily
    visitor_last_touch_daily
    visitor_first_seen_daily
    visitor_acquisition
    visitor_identity_map
    visitor_identities
    link_dimensions
  ].freeze

  # Tables with NO date-based retention — only wiped on full-project delete:
  #   user_profiles        — no date column
  #   visitor_acquisition  — whole-history argMin/argMax aggregate; no event_date
  #   visitor_first_seen_daily — whole-history min; pruning old partitions would make an old visitor look new
  #   visitor_identity_map — identity aliases must outlive any retention window or merges un-resolve
  #   visitor_identities   — current-state PG mirror; no date column
  #   link_dimensions      — current-state PG mirror; no date column
  # `events` (the single deduped store) IS date-retention-pruned by created_at, matching the
  # operational retention window (AnalyticsRetentionDeletionJob). Tradeoff/open decision: pruning
  # very old events erodes the whole-history visitor_acquisition rebuild source (a later
  # merge-triggered rebuild can drift install/first-touch beyond the window) — acceptable because
  # retention windows are long and first-touch older than the window is out of scope anyway.
  RETENTION_EXEMPT = %w[user_profiles visitor_acquisition visitor_first_seen_daily visitor_identity_map
                        visitor_identities link_dimensions].freeze

  # Retention cutoff column per table (purchase_events on purchase_date; else the daily event_date).
  RETENTION_DATE_COLUMNS = (PROJECT_TABLES - RETENTION_EXEMPT).index_with do |table|
    case table
    when "events"          then "created_at"
    when "purchase_events" then "purchase_date"
    else "event_date"
    end
  end.freeze

  # Redis tombstones guard against a resurrection race: a CH batch parked in the DLQ
  # before a project was deleted, then replayed by DrainCanonicalDlqJob AFTER the
  # ALTER…DELETE ran, would re-insert rows for a deleted (GDPR-erased) project. The
  # DLQ drain checks these tombstones and drops such rows. TTL must comfortably exceed
  # any realistic CH outage / DLQ backlog window.
  TOMBSTONE_PREFIX = "clickhouse:deleted_project"
  TOMBSTONE_TTL = 14.days.to_i

  def self.tombstone_key(project_id)
    "#{TOMBSTONE_PREFIX}:#{Integer(project_id)}"
  end

  # Delete all CH data for the given project IDs.
  # Fire-and-forget: logs errors but does not raise.
  def self.delete_projects(project_ids)
    unless Clickhouse.enabled?
      purge_spills(project_ids)
      return
    end

    ids = Array(project_ids).map { |id| Integer(id) }
    return if ids.empty?

    id_list = ids.join(',') # safe to interpolate: every id is Integer()-coerced above

    # Tombstone before mutating so a mid-delete failure can't leave erased tables un-tombstoned.
    tombstone_projects(ids)
    # after tombstoning, so a concurrent drain sees the tombstone first
    purge_spills(ids)

    Clickhouse.with do |conn|
      PROJECT_TABLES.each do |table|
        conn.execute("ALTER TABLE `#{table}` DELETE WHERE project_id IN (#{id_list})")
      end
    end
  rescue StandardError => e
    Rails.logger.error(
      "ClickhouseDeleteService: failed to delete projects #{project_ids.inspect} — " \
      "#{e.class}: #{e.message}"
    )
  end

  # Mark project IDs as deleted so a later DLQ replay can't resurrect their CH rows.
  def self.tombstone_projects(project_ids)
    ids = Array(project_ids).map { |id| Integer(id) }
    return if ids.empty?

    REDIS.with do |conn|
      conn.pipelined do |pipe|
        ids.each { |id| pipe.set(tombstone_key(id), "1", ex: TOMBSTONE_TTL) }
      end
    end
  rescue StandardError => e
    # Non-fatal: the ALTER…DELETE already ran; a missing tombstone only reopens the
    # rare replay race, it doesn't lose live data.
    Rails.logger.warn("ClickhouseDeleteService.tombstone_projects failed: #{e.class} - #{e.message}")
  end

  # Drop rows whose project was tombstoned (deleted). Used by the DLQ drain so replayed
  # batches can't resurrect a deleted project. Fails open (returns rows unchanged) on a
  # Redis error — a transient blip must never drop a live project's events.
  def self.reject_tombstoned(rows)
    return rows if rows.empty?

    pids = rows.filter_map { |r| r[:project_id] }.uniq
    tombstoned = tombstoned_project_ids(pids)
    return rows if tombstoned.empty?

    rows.reject do |r|
      pid = coerce_project_id(r[:project_id])
      pid && tombstoned.include?(pid)
    end
  end

  def self.coerce_project_id(value)
    Integer(value)
  rescue ArgumentError, TypeError
    nil
  end
  private_class_method :coerce_project_id

  # The subset of the given project IDs that are currently tombstoned.
  def self.tombstoned_project_ids(project_ids)
    ids = Array(project_ids).filter_map { |id| Integer(id) rescue nil }.uniq
    return [] if ids.empty?

    flags = REDIS.with do |conn|
      conn.pipelined { |pipe| ids.each { |id| pipe.exists(tombstone_key(id)) } }
    end
    ids.zip(flags).filter_map { |id, present| id if present.to_i.positive? }
  rescue StandardError => e
    Rails.logger.warn("ClickhouseDeleteService.tombstoned_project_ids failed: #{e.class} - #{e.message}")
    []
  end

  def self.purge_spills(project_ids)
    ClickhouseEventSpill.where(project_id: Array(project_ids)).delete_all if Array(project_ids).any?
  end
  private_class_method :purge_spills

  # Date-bounded per-project delete; per-table rescue, returns failures as [{table:,error:}].
  def self.delete_projects_before(project_ids, cutoff_date)
    ids = Array(project_ids).map { |id| Integer(id) }
    return [] if ids.empty?

    # old spills would resurrect expired data on drain; purge even when CH is disabled
    ClickhouseEventSpill.where(project_id: ids).where(event_created_at: ...cutoff_date.to_date).delete_all

    return [] unless Clickhouse.enabled?

    # ALTER…DELETE cannot take {name:Type} placeholders, so these values are interpolated:
    # ids are already Integer()-coerced above, and to_date.strftime guarantees cutoff is a
    # bare YYYY-MM-DD even if a caller passes a String — nothing user-shaped reaches the SQL.
    id_list = ids.join(',')
    cutoff = cutoff_date.to_date.strftime('%Y-%m-%d')
    errors = []

    Clickhouse.with do |conn|
      RETENTION_DATE_COLUMNS.each do |table, date_col|
        conn.execute(
          "ALTER TABLE `#{table}` DELETE " \
          "WHERE project_id IN (#{id_list}) AND toDate(`#{date_col}`) < toDate('#{cutoff}')"
        )
      rescue StandardError => e
        errors << { table: table, error: "#{e.class}: #{e.message}" }
        Rails.logger.error(
          "ClickhouseDeleteService#delete_projects_before #{table}: #{e.class}: #{e.message}"
        )
      end
    end

    errors
  rescue ArgumentError => e
    Rails.logger.error("ClickhouseDeleteService#delete_projects_before: bad project id — #{e.message}")
    []
  end
end
