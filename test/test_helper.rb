ENV['RAILS_ENV'] ||= 'test'
# Lock-skip retries must not sleep in tests.
ENV['CLICKHOUSE_REBUILD_LOCK_RETRY_SLEEP'] ||= '0'

# Coverage — opt-in via COVERAGE so normal runs stay fast. Must start before any
# application code is required so every line is instrumented. command_name lets the
# parallel-worker results AND a separate GROVS_EE run merge into one report.
# Analytics >=90% bar is enforced out-of-band (see script/check_analytics_coverage).
if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start "rails" do
    enable_coverage :branch
    command_name ENV.fetch("GROVS_EE", "false") == "true" ? "ee" : "core"
    add_filter %r{^/test/}
    add_filter %r{^/config/}
    add_filter %r{^/db/}
    add_filter "lib/rubocop"
    add_group "Analytics", %w[app/services/analytics app/controllers/api/v1/analytics]
    add_group "Services", "app/services"
    add_group "Serializers", "app/serializers"
    add_group "EE", "ee/app"
  end
end

require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require_relative "support/clickhouse_test_helper"
require_relative "support/golden_dataset_helper"
require_relative "support/ch_query_counter"
require_relative "support/analytics_sql_capture_helper"

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
  Dir[File.join(ee_test, "{support,contracts}/**/*.rb")].sort.each { |f| require f }
end

# Rails 8.1 defers route loading; ensure Devise mappings are available for tests
Rails.application.reload_routes!

# Ensure the default ClickHouse test database exists.
# Table creation is deferred to ClickhouseTestHelper.ensure_tables!
# (called lazily by tests that need it, or eagerly by parallelize_setup).
if ClickhouseTestHelper.available?
  Clickhouse.build_connection(database: 'default')
            .execute("CREATE DATABASE IF NOT EXISTS `#{Clickhouse.default_database}`")
end

# App pins :sidekiq on ActiveJob::Base, and Rails only auto-swaps jobs with no adapter set.
class ActiveJob::TestCase
  def queue_adapter_for_test
    ActiveJob::QueueAdapters::TestAdapter.new
  end
end

class ActiveSupport::TestCase
  # Workers are fully isolated (per-worker PG/Redis/ClickHouse databases, below).
  # PARALLEL_WORKERS=1 only to debug a failure serially.
  parallelize(workers: ENV.key?("PARALLEL_WORKERS") ? ENV["PARALLEL_WORKERS"].to_i : :number_of_processors)

  # Rails skips parallelize_setup below a 2-worker count, so a serial run would otherwise
  # inherit the previous run's Redis keys — long-TTL, fixture-id-keyed ones corrupt it.
  REDIS.flushdb if ENV.key?("PARALLEL_WORKERS") && ENV["PARALLEL_WORKERS"].to_i <= 1

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

    # Each parallel worker gets its own ClickHouse database.
    # Skipped entirely if ClickHouse isn't running — existing tests unaffected.
    if ClickhouseTestHelper.available?
      ch_db = "grovs_test_#{worker}"

      # Create worker database via admin connection to 'default'
      Clickhouse.build_connection(database: 'default')
                .execute("CREATE DATABASE IF NOT EXISTS `#{ch_db}`")

      # Reconfigure ClickHouse::Client to point to the worker database
      ClickHouse::Client.configuration.databases.delete(:main)
      raw_url = ENV.fetch('CLICKHOUSE_URL', 'http://localhost:8123')
      uri = URI.parse(raw_url)
      ClickHouse::Client.configuration.register_database(:main,
        database: ch_db,
        url: "#{uri.scheme}://#{uri.host}:#{uri.port || 8123}",
        username: uri.user || 'default',
        password: uri.password || '',
        variables: ClickhouseTestHelper::TEST_CLICKHOUSE_VARIABLES
      )
      Clickhouse.reset_connection!

      # Create tables (idempotent). Individual tests truncate in their own setup.
      ClickhouseTestHelper.ensure_tables!
    end
  end

  parallelize_teardown do |_worker|
    REDIS.flushdb
    SimpleCov.result if ENV["COVERAGE"] # flush before the fork exits
  end

  # Transactional rollback restores the DB but not Redis; fixture ids repeat, so any
  # id-keyed key left behind silently corrupts a later test (remapped events, discarded spills).
  setup do
    REDIS.with do |conn|
      # *:find_by:* — a test mutating any cached fixture re-caches it before the rollback Redis never sees.
      ["*:find_by:*", "#{BatchEventProcessorJob::MERGED_DEVICE_PREFIX}:*",
       "#{MergeVisitorEventsJob::LOCK_PREFIX}:*",
       "#{ClickhouseDeleteService::TOMBSTONE_PREFIX}:*",
       ReconcileLinkDimensionsJob::LOCK_KEY, ReconcileLinkDimensionsJob::SWEEP_CURSOR_KEY,
       "clickhouse:identity_sync:*",
       "#{BatchEventProcessorJob::DEDUP_PREFIX}:*"].each do |pattern|
        keys = conn.keys(pattern)
        conn.del(*keys) unless keys.empty?
      end
    end
  end

  # ClickHouse feature flags live on the process-global Rails.application.config
  # (per worker). Many tests toggle them; a test that fails to restore one would
  # silently disable CH reads/writes for every later test on the same worker
  # (e.g. attribution reads returning [] -> flaky empties under the combined
  # suite). Capture the boot/env values once and restore them after every test so
  # flag-toggling can never bleed across tests.
  CH_FLAG_ACCESSORS = %i[
    clickhouse_write_enabled clickhouse_read_enabled clickhouse_primary
    clickhouse_analytics_rollups_read_enabled clickhouse_attribution_read_enabled
    revenue_reads_from_ledger
  ].freeze
  CH_FLAG_DEFAULTS = CH_FLAG_ACCESSORS.index_with { |f| Rails.application.config.public_send(f) }.freeze

  # primary? implies the rollup/ledger flags, so a stray CLICKHOUSE_PRIMARY would
  # silently stop every legacy-branch suite from testing its legacy branch. Pin it off by default.
  setup { Rails.application.config.clickhouse_primary = false }

  # Tests assume a live rebuild; the staleness gate has its own suite and clears these itself.
  setup { ClickhouseRollupLiveness.record(:full) }
  teardown { ClickhouseRollupLiveness.clear! }

  teardown do
    CH_FLAG_DEFAULTS.each { |flag, value| Rails.application.config.public_send("#{flag}=", value) }
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
    GROVS_SELF_HOSTED CUSTOM_DOMAINS_PROVIDER
  ].freeze

  def enable_custom_domains!
    ENV["CUSTOM_DOMAINS_ENABLED"] = "true"
    ENV["CLOUDFLARE_API_TOKEN"] = "test-token"
    ENV["CLOUDFLARE_ZONE_ID"] = "test-zone"
    ENV["CLOUDFLARE_SAAS_CNAME_TARGET"] = "proxy.sqd.link"
    ENV.delete("GROVS_SELF_HOSTED")
    ENV.delete("CUSTOM_DOMAINS_PROVIDER")
  end

  # Clears the CF keys rather than assuming them unset, so the mode is deterministic locally.
  def enable_manual_custom_domains!
    CUSTOM_DOMAIN_ENV_KEYS.each { |k| ENV.delete(k) }
    ENV["CUSTOM_DOMAINS_ENABLED"] = "true"
    ENV["CUSTOM_DOMAINS_PROVIDER"] = "manual"
    ENV["GROVS_SELF_HOSTED"] = "true"
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
