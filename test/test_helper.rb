ENV['RAILS_ENV'] ||= 'test'
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

# Include ee/ test paths when enterprise features are enabled
if ENV.fetch("GROVS_EE", "false") == "true"
  ee_test = File.expand_path("../ee/test", __dir__)
  $LOAD_PATH.unshift(ee_test) if Dir.exist?(ee_test)
end

# Rails 8.1 defers route loading; ensure Devise mappings are available for tests
Rails.application.reload_routes!

class ActiveSupport::TestCase
  # Run tests in parallel with specified workers.
  # Use PARALLEL_WORKERS=1 to disable parallelism and avoid PG deadlocks on fixture setup.
  parallelize(workers: ENV.key?("PARALLEL_WORKERS") ? ENV["PARALLEL_WORKERS"].to_i : :number_of_processors)

  parallelize_setup do |worker|
    # Each parallel worker gets its own Redis database (0, 1, 2, ...)
    # to prevent key collisions between workers. Default Redis supports db 0-15.
    redis_url = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")
    worker_url = redis_url.sub(%r{/\d+\s*$}, "") + "/#{worker}"

    new_pool = ConnectionPool::Wrapper.new(size: REDIS_POOL_SIZE, timeout: 5) do
      Redis.new(url: worker_url, ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_NONE })
    end
    Object.send(:remove_const, :REDIS)
    Object.const_set(:REDIS, new_pool)

    REDIS.flushdb
  end

  parallelize_teardown do |_worker|
    REDIS.flushdb
  end

  # Load fixtures explicitly per test class to avoid NOT NULL constraint
  # violations from empty scaffold fixtures.

  # Compare JSON output (normalizes symbol/string key differences)
  def assert_json_equal(expected, actual, msg = nil)
    assert_equal JSON.parse(expected.to_json), JSON.parse(actual.to_json), msg
  end
end
