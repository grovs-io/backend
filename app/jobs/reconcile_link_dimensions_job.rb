# frozen_string_literal: true

# Repairs dropped dimension writes: docs/plans/2026-08-01-link-dimensions.md
class ReconcileLinkDimensionsJob
  include Sidekiq::Job

  sidekiq_options queue: :maintenance, retry: 3

  LockLost = Class.new(StandardError)

  LOOKBACK = 24.hours
  BATCH = 5_000
  LOCK_KEY = "link_dimensions:reconcile:lock"
  LOCK_TTL = 3_600
  SWEEP_CURSOR_KEY = "link_dimensions:reconcile:sweep_cursor"
  SWEEP_PROJECTS_PER_RUN = 25

  RELEASE_LUA = <<~LUA
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    else
      return 0
    end
  LUA

  RENEW_LUA = <<~LUA
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("expire", KEYS[1], ARGV[2])
    else
      return 0
    end
  LUA

  def perform(lookback_hours = nil)
    return unless Clickhouse.enabled? && Clickhouse.link_dimensions_read_enabled?
    return unless acquire_lock

    begin
      since = (lookback_hours&.to_i&.hours || LOOKBACK).ago
      resync_changed(since)
      # Before the id diff, which raises under primary on a bad read: only repair for old drift.
      sweep_attributes
      tombstone_deleted
    ensure
      release_lock
    end
  end

  private

  # Full-estate scans must not overlap: a slow run would otherwise race its own successor.
  def acquire_lock
    @lock_token = SecureRandom.hex(16)
    REDIS.with { |c| c.set(LOCK_KEY, @lock_token, nx: true, ex: LOCK_TTL) }
  end

  # Fail closed: continuing past a lost lease is what puts two reconcilers on the same estate.
  def renew_lock
    return if REDIS.with { |c| c.eval(RENEW_LUA, keys: [LOCK_KEY], argv: [@lock_token, LOCK_TTL.to_s]) }.to_i == 1

    raise LockLost, "lock lost"
  end

  # Compare-and-delete: a plain DEL after an expired lease would drop the successor's lock.
  def release_lock
    REDIS.with { |c| c.eval(RELEASE_LUA, keys: [LOCK_KEY], argv: [@lock_token]) }
  rescue StandardError => e
    Rails.logger.warn("ReconcileLinkDimensionsJob: lock release failed #{e.class}")
  end

  def resync_changed(since)
    Link.includes(:domain).where(updated_at: since..).find_in_batches(batch_size: BATCH) do |batch|
      renew_lock
      LinkDimensionSyncService.sync_all(batch)
    end
  end

  # Diffing both ways: a dropped tombstone has no Postgres row left to re-read.
  def tombstone_deleted
    Project.find_each { |project| reconcile_project(project) }
  end

  # Walks both sides in matching id windows so neither set is ever fully resident.
  def reconcile_project(project)
    domain_id = project.domain&.id
    return if domain_id.nil?

    after = 0
    tombstoned = 0
    resynced = 0

    loop do
      renew_lock
      ch_ids = ClickhouseReadService.link_dimension_ids(project.id, after_id: after, limit: BATCH)
      if ch_ids.nil?
        # Only reachable off primary, where unavailable! stays silent — on it, the read raises.
        Grovs::Metrics.increment("clickhouse.link_dimension.reconcile_skipped")
        Rails.logger.warn("ReconcileLinkDimensionsJob: project #{project.id} skipped, dimension read failed")
        return
      end

      # Postgres is paged too, or an empty mirror would load every remaining link at once.
      pg_ids = Link.where(domain_id: domain_id).where("id > ?", after).order(:id).limit(BATCH).pluck(:id)
      break if ch_ids.empty? && pg_ids.empty?

      # Compare only where both pages overlap, or a short side looks like mass divergence.
      ends = []
      ends << ch_ids.last if ch_ids.size == BATCH
      ends << pg_ids.last if pg_ids.size == BATCH
      window_end = ends.min

      ch_window = window_end ? ch_ids.take_while { |id| id <= window_end } : ch_ids
      pg_window = window_end ? pg_ids.take_while { |id| id <= window_end } : pg_ids

      # Sets on both sides: Array#include? is O(n) each, so 300k links would be ~90bn compares.
      ch_set = ch_window.to_set
      pg_set = pg_window.to_set

      orphans = ch_window.reject { |id| pg_set.include?(id) }
      if orphans.any?
        LinkDimensionSyncService.tombstone_missing(project.id, orphans)
        tombstoned += orphans.size
      end

      missing = pg_window.reject { |id| ch_set.include?(id) }
      missing.each_slice(BATCH) do |slice|
        # version: now, or a link buried by a wrong tombstone can never outrank it.
        LinkDimensionSyncService.sync_all(Link.includes(:domain).where(id: slice), version: Time.current)
      end
      resynced += missing.size

      break if window_end.nil?

      after = window_end
    end

    return if tombstoned.zero? && resynced.zero?

    Rails.logger.info("ReconcileLinkDimensionsJob: project #{project.id} " \
                      "tombstoned=#{tombstoned} resynced=#{resynced}")
  end

  # The id diff sees membership only: an attribute lost outside the lookback needs this sweep.
  def sweep_attributes
    cursor = REDIS.with { |c| c.get(SWEEP_CURSOR_KEY) }.to_i
    projects = Project.where("id > ?", cursor).order(:id).limit(SWEEP_PROJECTS_PER_RUN).to_a
    projects = Project.order(:id).limit(SWEEP_PROJECTS_PER_RUN).to_a if projects.empty?
    return if projects.empty?

    projects.each do |project|
      domain_id = project.domain&.id
      next if domain_id.nil?

      # No version bump: these rows already exist, so a concurrent user edit must keep winning.
      Link.includes(:domain).where(domain_id: domain_id).find_in_batches(batch_size: BATCH) do |batch|
        renew_lock
        LinkDimensionSyncService.sync_all(batch)
      end
    end

    # Only after every project above wrote: a raise here leaves the cursor for the next run.
    REDIS.with { |c| c.set(SWEEP_CURSOR_KEY, projects.last.id.to_s) }
  end
end
