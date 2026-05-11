class CoalescedMergeJob
  include Sidekiq::Job
  sidekiq_options queue: :events, retry: 2

  LOCK_TTL = 300 # 5 minutes — generous ceiling for sequential drain
  MAX_ATTEMPTS = 5
  RETRY_DELAY = 30 # seconds — backoff between drain attempts for transient errors
  SET_PREFIX = "merge_sources"
  LOCK_PREFIX = "merge_lock"
  PENDING_PREFIX = "merge_pending"
  FAILURES_PREFIX = "merge_failures"

  # Lua script: release lock only if we still own it (atomic check-and-delete).
  # This is a standard Redis distributed lock pattern (Redlock), not arbitrary code.
  RELEASE_LOCK_SCRIPT = <<~LUA.freeze
    if redis.call('get', KEYS[1]) == ARGV[1] then
      return redis.call('del', KEYS[1])
    else
      return 0
    end
  LUA

  def perform(to_device_id, project_id)
    set_key  = "#{SET_PREFIX}:#{to_device_id}:#{project_id}"
    lock_key = "#{LOCK_PREFIX}:#{to_device_id}:#{project_id}"
    lock_value = SecureRandom.hex(16)

    # Acquire processing lock — if another job is draining this target, bail.
    # Items stay in the set and will be picked up when the running job re-checks.
    return unless REDIS.set(lock_key, lock_value, nx: true, ex: LOCK_TTL)

    had_failures = false
    begin
      had_failures = drain(to_device_id, project_id, set_key)
    ensure
      release_lock(lock_key, lock_value)
    end

    # Always clear the pending key so new arrivals can enqueue a fresh job.
    # Then re-enqueue ourselves if items remain (new arrivals or failed merges).
    # Use delayed re-enqueue after failures so transient DB errors (lock/statement
    # timeouts) have time to resolve — prevents burning through MAX_ATTEMPTS in seconds.
    pending_key = "#{PENDING_PREFIX}:#{to_device_id}:#{project_id}"
    REDIS.del(pending_key)

    if REDIS.scard(set_key) > 0
      if had_failures
        CoalescedMergeJob.perform_in(RETRY_DELAY, to_device_id, project_id)
      else
        CoalescedMergeJob.perform_async(to_device_id, project_id)
      end
    end
  end

  private

  # Returns true if any source failed during this drain.
  def drain(to_device_id, project_id, set_key)
    source_ids = REDIS.smembers(set_key)
    merge_job = MergeVisitorEventsJob.new
    failures_key = "#{FAILURES_PREFIX}:#{to_device_id}:#{project_id}"
    had_failures = false

    source_ids.each do |from_device_id_str|
      begin
        merge_job.perform(from_device_id_str.to_i, to_device_id, project_id)
      rescue => e
        had_failures = true
        attempts = REDIS.hincrby(failures_key, from_device_id_str, 1)
        REDIS.expire(failures_key, 86_400) # 24h safety net
        if attempts >= MAX_ATTEMPTS
          REDIS.srem?(set_key, from_device_id_str)
          REDIS.hdel(failures_key, from_device_id_str)
          Rails.logger.error(
            "CoalescedMergeJob: #{from_device_id_str}->#{to_device_id} (project #{project_id}) dead-lettered after #{attempts} attempts: #{e.class} #{e.message}"
          )
        else
          Rails.logger.warn(
            "CoalescedMergeJob: #{from_device_id_str}->#{to_device_id} (project #{project_id}) attempt #{attempts}/#{MAX_ATTEMPTS} failed: #{e.class} #{e.message}"
          )
        end
        next
      end
      REDIS.srem?(set_key, from_device_id_str)
      REDIS.hdel(failures_key, from_device_id_str)
    end

    REDIS.del(failures_key) if REDIS.hlen(failures_key) == 0
    had_failures
  end

  def release_lock(key, value)
    # Atomic check-and-delete via Redis Lua — standard distributed lock release pattern
    REDIS.eval(RELEASE_LOCK_SCRIPT, keys: [key], argv: [value])
  end
end
