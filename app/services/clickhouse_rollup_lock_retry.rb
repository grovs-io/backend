# frozen_string_literal: true

# The recurring job holds the same lock and rebuilds exactly what we want — wait it out.
module ClickhouseRollupLockRetry
  ATTEMPTS = Integer(ENV.fetch("CLICKHOUSE_REBUILD_LOCK_RETRY_ATTEMPTS", 12))

  # Returns [still_skipped, errors]; a raise is a real failure, not a lock-skip.
  # wait_for_lock: only the one-shot repair blocks; a recurring lane's skip is benign.
  def self.call(skipped, wait_for_lock: true)
    return [skipped, []] unless wait_for_lock

    last_error = {}
    ATTEMPTS.times do
      break if skipped.empty?

      sleep(Integer(ENV.fetch("CLICKHOUSE_REBUILD_LOCK_RETRY_SLEEP", 5)))
      skipped = skipped.reject do |pair|
        yield(*pair)
      rescue StandardError => e
        last_error[pair] = "#{e.class}: #{e.message}"
        false
      end
    end
    errors = skipped.filter_map do |pair|
      last_error[pair] && { rollup: pair[0], partition: pair[1], error: last_error[pair] }
    end
    [skipped, errors]
  end
end
