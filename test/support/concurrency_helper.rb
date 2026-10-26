module ConcurrencyHelper
  SCALE = Integer(ENV.fetch("CONCURRENCY_SCALE", "1"))
  THREADS = Integer(ENV.fetch("CONCURRENCY_THREADS", "8"))
  JOIN_TIMEOUT = 300

  # They commit real rows and resize the pool, so they only run serially via `rails test:concurrency`.
  def self.included(base)
    base.setup { skip "run with bin/rails test:concurrency" unless concurrency_enabled? }
  end

  def concurrency_enabled? = ENV["CONCURRENCY"] == "1"

  def scaled(count) = count * SCALE

  # The test pool defaults to 5; every racing thread needs its own real connection.
  def ensure_pool!(size = THREADS + 2)
    return if ActiveRecord::Base.connection_pool.size >= size

    ActiveRecord::Base.establish_connection(ActiveRecord::Base.connection_db_config.configuration_hash.merge(pool: size))
  end

  # Runs the block on `count` threads released together; re-raises the first thread error.
  def run_concurrently(count = THREADS)
    ensure_pool!(count + 2)
    barrier = Concurrent::CyclicBarrier.new(count)
    threads = Array.new(count) do |i|
      Thread.new do
        Thread.current.report_on_exception = false
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          conn.execute("SELECT 1")
          barrier.wait(30) or raise "barrier timeout"
          yield i
        end
      end
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + JOIN_TIMEOUT
    hung = threads.reject { |t| finished?(t, deadline) }
    # Never let a stray worker keep writing while teardown deletes its rows.
    hung.each { |t| t.kill.join(5) }
    flunk "#{hung.size} thread(s) still running after #{JOIN_TIMEOUT}s (lock wait or deadlock)" if hung.any?
    threads.map(&:value)
  end

  def finished?(thread, deadline)
    thread.join([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)
  rescue StandardError
    true
  end

  # Red on current code; CONCURRENCY_KNOWN_BUGS=1 runs it. Delete the call once the bug is fixed.
  def skip_known_bug!(bug)
    skip "known concurrency bug: #{bug}" unless ENV["CONCURRENCY_KNOWN_BUGS"] == "1"
  end

  def deadlock?(error)
    error.is_a?(ActiveRecord::Deadlocked) || error.message.include?("deadlock detected")
  end

  def redis_del_matching(*patterns)
    REDIS.with do |conn|
      patterns.each do |pattern|
        keys = conn.keys(pattern)
        conn.del(*keys) unless keys.empty?
      end
    end
  end
end
