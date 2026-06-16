ENV['RAILS_ENV'] ||= 'test'

# Must start before the app loads. Usage: COVERAGE=1 bundle exec rails test:full
if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start "rails" do
    enable_coverage :branch
    command_name ENV.fetch("GROVS_EE", "false") == "true" ? "ee" : "core"
    add_group "Services", "app/services"
    add_group "Serializers", "app/serializers"
    add_group "EE", "ee/app"
    add_filter "lib/rubocop"
  end
end

require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

# Strict API request/response contract lock. Loads the registry + schemas, then
# hooks every integration request so registered endpoints are validated. See
# test/support/api_contracts.rb and ApiContractCoverageTest for the coverage gate.
Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }
Dir[File.expand_path("contracts/**/*.rb", __dir__)].sort.each { |f| require f }
ActionDispatch::IntegrationTest.prepend(ApiContracts::IntegrationHook)

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
    SimpleCov.command_name "#{SimpleCov.command_name}-worker#{worker}" if ENV["COVERAGE"]

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
    SimpleCov.result if ENV["COVERAGE"] # flush before the fork exits
  end

  # Transactional rollback restores the DB but not the Redis model cache;
  # purge CustomHostname entries so sibling-test flips don't leak.
  setup do
    REDIS.with do |conn|
      keys = conn.keys("custom_hostnames:find_by:*")
      conn.del(*keys) unless keys.empty?
    end
  end

  # Load fixtures explicitly per test class to avoid NOT NULL constraint
  # violations from empty scaffold fixtures.

  # Compare JSON output (normalizes symbol/string key differences)
  def assert_json_equal(expected, actual, msg = nil)
    assert_equal JSON.parse(expected.to_json), JSON.parse(actual.to_json), msg
  end

  # Custom-domains feature flag toggles for tests. The flag is off unless
  # CUSTOM_DOMAINS_ENABLED plus the three Cloudflare creds are present. enable! forces
  # it on; disable! forces it off by deleting all four keys — so the disabled-path
  # tests are deterministic even when a developer's .env sets these locally (dotenv
  # loads .env in the test env). Enabled-path tests call enable! in setup and
  # disable! in teardown.
  CUSTOM_DOMAIN_ENV_KEYS = %w[
    CUSTOM_DOMAINS_ENABLED CLOUDFLARE_API_TOKEN CLOUDFLARE_ZONE_ID CLOUDFLARE_SAAS_CNAME_TARGET
  ].freeze

  def enable_custom_domains!
    ENV["CUSTOM_DOMAINS_ENABLED"] = "true"
    ENV["CLOUDFLARE_API_TOKEN"] = "test-token"
    ENV["CLOUDFLARE_ZONE_ID"] = "test-zone"
    ENV["CLOUDFLARE_SAAS_CNAME_TARGET"] = "proxy.sqd.link"
  end

  def disable_custom_domains!
    CUSTOM_DOMAIN_ENV_KEYS.each { |k| ENV.delete(k) }
  end

  # Migrate-from-competitors test helpers. Migration depends on custom domains, so we enable
  # both for any test that exercises the migration code path.
  MIGRATION_ENV_KEYS = (CUSTOM_DOMAIN_ENV_KEYS + %w[MIGRATIONS_ENABLED]).freeze

  def enable_migrations!
    enable_custom_domains!
    ENV["MIGRATIONS_ENABLED"] = "true"
  end

  def disable_migrations!
    MIGRATION_ENV_KEYS.each { |k| ENV.delete(k) }
  end
end
