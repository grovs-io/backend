# # Puma can serve each request in a thread from an internal thread pool.
# # The `threads` method setting takes two numbers: a minimum and maximum.
# # Any libraries that use thread pools should be configured to match
# # the maximum value specified for Puma. Default is set to 5 threads for minimum
# # and maximum; this matches the default thread size of Active Record.
# #
# max_threads_count = ENV.fetch("RAILS_MAX_THREADS") { 5 }
# min_threads_count = ENV.fetch("RAILS_MIN_THREADS") { max_threads_count }
# threads min_threads_count, max_threads_count

# # Specifies the `worker_timeout` threshold that Puma will use to wait before
# # terminating a worker in development environments.
# #
# worker_timeout 3600 if ENV.fetch("RAILS_ENV", "development") == "development"

# # Specifies the `port` that Puma will listen on to receive requests; default is 3000.
# #
# port ENV.fetch("PORT") { 3000 }

# # Specifies the `environment` that Puma will run in.
# #
# environment ENV.fetch("RAILS_ENV") { "development" }

# # Specifies the `pidfile` that Puma will use.
# pidfile ENV.fetch("PIDFILE") { "tmp/pids/server.pid" }

# # Specifies the number of `workers` to boot in clustered mode.
# # Workers are forked web server processes. If using threads and workers together
# # the concurrency of the application would be max `threads` * `workers`.
# # Workers do not work on JRuby or Windows (both of which do not support
# # processes).
# #
# # workers ENV.fetch("WEB_CONCURRENCY") { 2 }

# # Use the `preload_app!` method when specifying a `workers` number.
# # This directive tells Puma to first boot the application and load code
# # before forking the application. This takes advantage of Copy On Write
# # process behavior so workers use less memory.
# #
# # preload_app!

# # Allow puma to be restarted by `rails restart` command.
# plugin :tmp_restart


workers Integer(ENV['WEB_CONCURRENCY'] || 8)  # Set to 4 for Performance-M dynos

# Set the number of threads per worker
threads_count = Integer(ENV['RAILS_MAX_THREADS'] || 32)  # 5–10 threads per worker is good
threads threads_count, threads_count

# Allow Puma to be used in a clustered mode with multiple workers
preload_app!

port        ENV.fetch("PORT", 3000)
environment ENV['RACK_ENV'] || 'production'

on_worker_boot do
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord)

  # Re-create Redis pool after fork. ConnectionPool is lazy so usually
  # no TCP connections exist pre-fork, but this guards against future
  # initializers that might call REDIS before fork — shared file
  # descriptors across forked workers cause garbled data / ECONNRESET.
  begin
    if defined?(::REDIS) && defined?(new_redis_pool)
      new_pool = new_redis_pool
      Object.send(:remove_const, :REDIS)
      Object.const_set(:REDIS, new_pool)
    end
  rescue StandardError => e
    Rails.logger.error("Failed to re-create Redis pool in worker: #{e.message}") if defined?(Rails)
  end
end