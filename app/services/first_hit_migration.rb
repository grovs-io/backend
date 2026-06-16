require "digest"

# SETNX single-flight on (source, old_path) ensures exactly one Link is materialized per
# slug under concurrent first-clicks. Losers serve project_defaults immediately (no
# blocking) to avoid thundering-herd thread-pool exhaustion.
class FirstHitMigration
  LOCK_TTL_SECONDS = 10
  # Per-source upstream call ceiling. Circuit breaker against pathologies (Redis flush,
  # scanner attacks, regression that bypasses MigratedLink cache) — NOT a normal-traffic
  # quota. Sized at ~100/sec to align with Branch/AppsFlyer typical per-customer ceilings,
  # so legitimate viral first-hit traffic isn't degraded to project_defaults.
  UPSTREAM_RATE_LIMIT_PER_MINUTE = 6000

  # Lua script for atomic CAS-unlock (NOT Ruby Kernel#eval — Redis EVAL).
  RELEASE_LOCK_LUA = "if redis.call(\"get\", KEYS[1]) == ARGV[1] then return redis.call(\"del\", KEYS[1]) else return 0 end".freeze

  def self.call(source:, old_path:, query_string: "")
    lock_key = "migration:lock:#{source.id}:#{Digest::SHA1.hexdigest(old_path)}"
    # Tokened lock so a TTL-expired winner can't stomp a successor's lock on release.
    token = SecureRandom.hex(16)

    acquired = REDIS.with { |c| c.set(lock_key, token, nx: true, ex: LOCK_TTL_SECONDS) }
    return MigrationOutcome.project_defaults(source.project, provider: source.provider) unless acquired

    unless upstream_rate_limit_ok?(source)
      Grovs::Metrics.increment("migration.upstream.rate_limited", tags: { provider: source.provider })
      release_lock(lock_key, token)
      return MigrationOutcome.project_defaults(source.project, provider: source.provider)
    end

    begin
      perform_upstream_resolution(source: source, old_path: old_path, query_string: query_string)
    ensure
      release_lock(lock_key, token)
    end
  end

  def self.release_lock(lock_key, token)
    REDIS.with { |conn| conn.eval(RELEASE_LOCK_LUA, keys: [lock_key], argv: [token]) }
  rescue Redis::BaseError, StandardError => e
    Rails.logger.warn(message: "first_hit_migration_release_lock_failed",
                      lock_key: lock_key, error: e.message)
  end

  # Sliding-window per-source per-minute counter. Fails open on Redis errors.
  def self.upstream_rate_limit_ok?(source)
    bucket = (Time.current.to_i / 60)
    key = "migration:upstream_rate:#{source.id}:#{bucket}"
    count = REDIS.with do |c|
      c.multi do |pipe|
        pipe.incr(key)
        pipe.expire(key, 65)
      end
    end.first
    count <= UPSTREAM_RATE_LIMIT_PER_MINUTE
  rescue Redis::BaseError, StandardError => e
    Grovs::Metrics.increment("migration.upstream.rate_limit_check_failed",
                              tags: { provider: source.provider })
    Rails.logger.warn(message: "migration_upstream_rate_limit_check_failed",
                      source_id: source.id, error: e.message)
    true
  end

  def self.perform_upstream_resolution(source:, old_path:, query_string:)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = MigrationProviderClient.for(source).fetch(old_path, query_string: query_string)
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).to_i

    Grovs::Metrics.increment("migration.upstream.calls",
                              tags: { provider: source.provider, outcome: result.outcome })
    Grovs::Metrics.histogram("migration.upstream.latency_ms", elapsed_ms,
                              tags: { provider: source.provider })

    case result.outcome
    when :found             then handle_found(source, old_path, query_string, result)
    when :not_found         then handle_not_found(source, old_path)
    when :transient_error   then handle_transient_error(source, old_path, result)
    end
  end

  # Excludes created_at (preserves first-hit timestamp across re-resolution) and
  # updated_at (Rails 8.1 auto-appends it — including here triggers a SQL syntax error).
  UPSERT_UPDATE_ONLY = %i[status link_id cached_until].freeze
  BUILDER_FAILURE_CACHE_TTL = 5.minutes

  def self.handle_found(source, old_path, query_string, result)
    link = nil
    ApplicationRecord.transaction do
      link = MigratedLinkBuilder.call(project: source.project, payload: result.payload)
      raise ActiveRecord::Rollback if link.nil?
      upsert_migrated_link(
        source: source, old_path: old_path,
        status: MigratedLink::STATUS_RESOLVED, link_id: link.id, cached_until: nil
      )
    end
    if link.nil?
      # Builder returned nil (project missing domain/redirect_config). Cache a short
      # transient row so repeat clicks don't burn upstream quota until the operator fixes it.
      upsert_migrated_link(
        source: source, old_path: old_path,
        status: MigratedLink::STATUS_TRANSIENT_ERROR, link_id: nil,
        cached_until: BUILDER_FAILURE_CACHE_TTL.from_now
      )
      MigratedLink.invalidate_cache_for(migration_source_id: source.id, old_path: old_path)
      source.record_failure!(0)
      return MigrationOutcome.project_defaults(source.project, provider: source.provider)
    end
    # upsert bypasses after_commit — invalidate manually so a stale negative-cache row
    # doesn't mask the freshly-resolved one.
    MigratedLink.invalidate_cache_for(migration_source_id: source.id, old_path: old_path)
    source.record_success!
    MigrationOutcome.redirect(link, query_string: query_string, provider: source.provider)
  end

  def self.handle_not_found(source, old_path)
    upsert_migrated_link(
      source: source, old_path: old_path,
      status: MigratedLink::STATUS_NOT_FOUND, link_id: nil, cached_until: 24.hours.from_now
    )
    MigratedLink.invalidate_cache_for(migration_source_id: source.id, old_path: old_path)
    source.record_success!
    MigrationOutcome.project_defaults(source.project, provider: source.provider)
  end

  def self.handle_transient_error(source, old_path, result)
    # Write cache row before record_failure! so a crash between them still leaves the
    # cache protecting upstream. Backoff uses the post-increment count.
    ttl = result.retry_after || backoff_for(source.consecutive_failures + 1)
    upsert_migrated_link(
      source: source, old_path: old_path,
      status: MigratedLink::STATUS_TRANSIENT_ERROR, link_id: nil, cached_until: ttl.seconds.from_now
    )
    MigratedLink.invalidate_cache_for(migration_source_id: source.id, old_path: old_path)
    source.record_failure!(result.http_status)
    MigrationOutcome.project_defaults(source.project, provider: source.provider)
  end

  def self.upsert_migrated_link(source:, old_path:, status:, link_id:, cached_until:)
    now = Time.current
    MigratedLink.upsert(
      {
        migration_source_id: source.id,
        old_path: old_path,
        status: status,
        link_id: link_id,
        cached_until: cached_until,
        created_at: now,
        updated_at: now
      },
      unique_by: [:migration_source_id, :old_path],
      update_only: UPSERT_UPDATE_ONLY
    )
  end

  BACKOFF_LADDER = [5, 30, 60, 300, 1800, 3600].freeze
  def self.backoff_for(failure_count)
    BACKOFF_LADDER[failure_count.clamp(1, BACKOFF_LADDER.size) - 1]
  end
end
