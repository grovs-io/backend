# frozen_string_literal: true

module Clickhouse
  # A CH read answered nil (unavailable). Under primary there is no PG fallback left.
  class Unavailable < StandardError; end

  # The rollups are not being rebuilt, so they would answer 0 instead of failing.
  class Stale < StandardError; end

  # Candidate-id costs and the thresholds below: docs/plans/2026-07-31-clickhouse-id-list-cost.md
  MAX_QUERY_SIZE = 8 * 1024 * 1024
  MAX_IN_LIST_IDS = 20_000

  # The gem default logs the whole interpolated statement; at the cap that is ~800 KB a query.
  LOG_PROC = ->(query) { query.to_sql.truncate(2_000) }

  # Row-at-a-time writers let the server batch, or each save is its own part. Off in test: the suite reads back.
  ASYNC_INSERT = Rails.env.test? ? {} : { async_insert: 1, wait_for_async_insert: 0 }.freeze

  class Connection
    def initialize(database = :main, configuration = ClickHouse::Client.configuration)
      @database = database
      @configuration = configuration
    end

    def select_all(sql)
      ClickhouseRollupLiveness.gate!(sql)
      ClickHouse::Client.select(sql, @database, @configuration)
    end

    def select_value(sql)
      result = select_all(sql)
      result.first&.values&.first
    end

    def select_one(sql)
      select_all(sql).first
    end

    def execute(sql)
      ClickHouse::Client.execute(sql, @database, @configuration)
    end

    def insert(table, rows, settings: {})
      return if rows.empty?

      # Send INSERT query as URL param and data as POST body — same pattern
      # GitLab uses for insert_csv. ClickHouse's HTTP interface expects this
      # split for bulk writes; embedding JSONEachRow in the query param
      # would exceed URI length limits on real batches.
      db = @configuration.databases[@database]
      url = db.build_custom_uri(extra_variables: settings.merge(
        query: "INSERT INTO `#{table}` FORMAT JSONEachRow"
      )).to_s

      body = rows.map(&:to_json).join("\n")

      response = @configuration.http_post_proc.call(url, db.headers, body)
      raise ClickHouse::Client::DatabaseError, "INSERT failed: #{response.body}" unless response.success?
    end
  end

  class << self
    def with
      yield connection
    end

    def connection
      @connection ||= Connection.new
    end

    def enabled?
      Rails.application.config.clickhouse_write_enabled
    end

    def read_enabled?
      Rails.application.config.clickhouse_read_enabled
    end

    # Events go to CH only; failures spill to PG for replay. Default OFF.
    def primary?
      Rails.application.config.clickhouse_primary
    end

    def primary_allowed?(primary:, write:, read:)
      return false unless primary
      return true if write && read

      Rails.logger&.error("CLICKHOUSE_PRIMARY requires CLICKHOUSE_WRITE_ENABLED and CLICKHOUSE_READ_ENABLED — ignoring flag")
      false
    end

    # Metered primary must bill from CH — gate on the wiring constant, not an env ack
    # an operator could set on a build without the wiring (billing off empty PG).
    def validate_primary_billing_wiring!(primary:, self_hosted:, mau_source:)
      return unless primary && !self_hosted
      return if mau_source == :clickhouse

      raise "CLICKHOUSE_PRIMARY on a metered deployment requires the MAU chain wired to " \
            "ClickHouse (ProjectService::MAU_SOURCE must be :clickhouse, got #{mau_source.inspect})"
    end

    # Transport failures — the connection never produced a ClickHouse answer at all.
    TRANSPORT_ERRORS = [IOError, SystemCallError, Timeout::Error, SocketError].freeze

    # DatabaseError covers BOTH outages and defects (unknown identifier, syntax, auth), so it
    # is classified by code the way Analytics::QueryHelpers::HEAVY does. Anything unmatched is
    # a bug and must surface as itself: a 500 naming it beats a retryable 503 nobody pages on.
    AVAILABILITY_CODES = /Code:\s*(159|202|209|210|241)\b|TIMEOUT_EXCEEDED|NETWORK_ERROR|MEMORY_LIMIT_EXCEEDED/

    def availability_error?(error)
      return true if TRANSPORT_ERRORS.any? { |klass| error.is_a?(klass) }
      return false unless error.is_a?(ClickHouse::Client::DatabaseError)
      # The gem raises with the response body alone, so a body carrying no ClickHouse code means
      # something in front of CH answered (proxy 502, HTML, empty) — an outage, not our SQL.
      return true unless error.message.match?(/Code:\s*\d+/)

      error.message.match?(AVAILABILITY_CODES)
    end

    # Called from the two read-service failure hooks, never from a caller: a CH read that
    # failed has no Postgres answer left under primary, so it must not return a value at all.
    def unavailable!(surface, error = nil)
      return unless primary?
      raise error if error && !availability_error?(error)

      Grovs::Metrics.increment("clickhouse.read.unavailable", tags: { surface: surface })
      raise Unavailable, [surface, error&.class].compact.join(": ")
    end

    # :events fallbacks go cold the moment primary flips; :stats ones survive until shadow writes stop.
    def id_cap_exceeded!(surface, cap, fallback: :stats)
      Grovs::Metrics.increment("clickhouse.read.id_cap_exceeded", tags: { surface: surface })
      return if fallback == :events ? !primary? : Grovs.pg_shadow_writes?

      raise Unavailable, "#{surface}: candidate id set over #{cap}"
    end

    # Writes off freezes the mirror; reads off makes every dimension query a silent nil fallback.
    def validate_link_dimensions_wiring!(reads:, writes:, ch_reads:)
      return unless reads
      return if writes && ch_reads

      raise "CLICKHOUSE_LINK_DIMENSIONS_READ_ENABLED requires CLICKHOUSE_WRITE_ENABLED " \
            "(#{writes}) and CLICKHOUSE_READ_ENABLED (#{ch_reads}) — without writes the " \
            "link_dimensions mirror never updates, and without reads every dimension query " \
            "falls back silently forever. Run rake link_dimensions:backfill before enabling reads."
    end

    # A read flag without CH reads+writes serves silent zeros with no PG fallback.
    def validate_analytics_reads_wiring!(reads:, writes:, ch_reads:)
      return unless reads
      return if writes && ch_reads

      raise "CLICKHOUSE_ANALYTICS_ROLLUPS_READ_ENABLED / CLICKHOUSE_ATTRIBUTION_READ_ENABLED " \
            "require CLICKHOUSE_WRITE_ENABLED (#{writes}) and CLICKHOUSE_READ_ENABLED (#{ch_reads}) — " \
            "without both, dashboards render zeros with no Postgres fallback."
    end

    # Shadow writes off leaves the PG stat tables cold, so only CH can still answer.
    def validate_shadow_writes_wiring!(primary:, shadow_writes:)
      return if shadow_writes || primary

      raise "PG_SHADOW_WRITES=false requires CLICKHOUSE_PRIMARY — with both off nothing writes " \
            "the Postgres stat tables and analytics would serve zeros. NOTE: CLICKHOUSE_PRIMARY is " \
            "downgraded to false (logged above) unless CLICKHOUSE_WRITE_ENABLED and " \
            "CLICKHOUSE_READ_ENABLED are both set — check those first"
    end

    # Per-metric staging flag; CH-primary implies it — flipping it off no longer reverts to PG.
    def analytics_rollups_read_enabled?
      primary? || Rails.application.config.clickhouse_analytics_rollups_read_enabled
    end

    # Backfill link_dimensions BEFORE enabling: an unfilled table filters every link away.
    def link_dimensions_read_enabled?
      Rails.application.config.clickhouse_link_dimensions_read_enabled
    end

    # Deliberately NOT primary-implied: per-visitor attribution is different math from the
    # count rollups, and primary already routes sources_breakdown to CH via the rollups.
    def attribution_read_enabled?
      Rails.application.config.clickhouse_attribution_read_enabled
    end

    # Build a one-off connection for admin tasks (non-pooled, specific database).
    def build_connection(database:)
      Connection.new(:main, build_configuration(database: database))
    end

    def default_database
      # Read from the already-configured client so rake tasks stay
      # consistent with the YAML / env var config the app actually uses.
      db = ClickHouse::Client.configuration.databases[:main]
      db ? db.database : ENV.fetch('CLICKHOUSE_DATABASE') { "grovs_#{Rails.env}" }
    end

    # Reset cached connection (used after fork in Puma/test workers).
    def reset_connection!
      @connection = nil
    end

    # Bound connect AND read for CH requests inside the block (honored by build_http_post_proc).
    def with_request_timeout(seconds)
      previous = Thread.current[:clickhouse_read_timeout_override]
      Thread.current[:clickhouse_read_timeout_override] = seconds
      yield
    ensure
      Thread.current[:clickhouse_read_timeout_override] = previous
    end

    def build_http_post_proc
      lambda { |url, headers, body|
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        # Connect is bounded by the override too, but never RAISED above the 10s default —
        # a long read budget must not also mean a long wait on an unreachable host.
        override = Thread.current[:clickhouse_read_timeout_override]
        http.open_timeout = override ? [Integer(override), 10].min : 10
        # SELECT-class reads get a 30s ceiling, just above CH's 25s max_execution_time
        # guard, so a runaway analytics query fails fast instead of hanging for 120s.
        # Everything else keeps the long window: INSERTs (String JSONEachRow body),
        # streaming CSV imports (IO body), AND write/DDL statements run via execute
        # (INSERT…SELECT, ALTER, CREATE) — the gem sends those as a Hash body too, so we
        # gate on the actual statement, not the body class, or heavy CH→CH writes would
        # be dropped at 30s. Both env-overridable.
        read_sql = body.is_a?(Hash) ? body['query'].to_s : ''
        # A caller-supplied per-request override wins over the statement-class default.
        http.read_timeout = if override
                              Integer(override)
                            elsif read_sql.lstrip.match?(/\A(?:SELECT|WITH|SHOW|DESCRIBE|DESC|EXPLAIN)\b/i)
                              Integer(ENV.fetch('CLICKHOUSE_HTTP_READ_TIMEOUT', 30))
                            else
                              Integer(ENV.fetch('CLICKHOUSE_HTTP_IMPORT_TIMEOUT', 120))
                            end
        # Body too: a peer that accepts TCP then stops reading would hang for Net::HTTP's 60s default.
        http.write_timeout = http.read_timeout

        if body.respond_to?(:read)
          # Streaming body (CSV imports)
          request = Net::HTTP::Post.new(uri.request_uri, headers)
          request.body_stream = body
        elsif body.is_a?(Hash)
          # The statement goes in the POST body, everything else (param_*, settings) in the URI.
          # Poco parses URI query values as form fields capped at http_max_field_value_size
          # (128 KiB, server-config only), so a query carrying a large IN list must not ride there.
          existing = URI.decode_www_form(uri.query || '')
          body.except('query').each { |k, v| existing << [k.to_s, v.to_s] }
          # Set here, not at registration: re-registering the database (test workers do) drops it.
          existing << ['max_query_size', MAX_QUERY_SIZE.to_s] unless existing.any? { |k, _| k == 'max_query_size' }
          uri.query = URI.encode_www_form(existing)
          request = Net::HTTP::Post.new(uri.request_uri, headers)
          request.body = read_sql
        else
          request = Net::HTTP::Post.new(uri.request_uri, headers)
          request.body = body
        end

        response = http.request(request)
        # Net::HTTP#to_hash returns {"header" => ["value"]} — flatten to {"header" => "value"}
        # for compatibility with click_house-client's Response which expects string values.
        flat_headers = response.to_hash.transform_values { |v| v.is_a?(Array) ? v.first : v }
        ClickHouse::Client::Response.new(response.body, response.code.to_i, flat_headers)
      }
    end

    private

    def build_configuration(database:)
      raw_url = ENV.fetch('CLICKHOUSE_URL', 'http://localhost:8123')
      uri = URI.parse(raw_url)

      ClickHouse::Client::Configuration.new.tap do |config|
        # RFC-3986 percent-decode (preserves literal '+', unlike decode_www_form_component).
        config.register_database(:main,
          database: database,
          url: "#{uri.scheme}://#{uri.host}:#{uri.port || 8123}",
          username: uri.user ? URI::DEFAULT_PARSER.unescape(uri.user) : 'default',
          password: uri.password ? URI::DEFAULT_PARSER.unescape(uri.password) : ''
        )

        config.http_post_proc = build_http_post_proc
        config.json_parser = JSON
        config.logger = Rails.logger
        config.log_proc = LOG_PROC
      end
    end
  end
end

# Configure ClickHouse::Client from YAML + env var overrides.
# Falls back to env vars / defaults when the YAML file is missing or
# has no section for the current environment (e.g. production, staging).
ch_config_file = Rails.root.join("config/click_house.yml")
ch_yaml = if ch_config_file.exist?
            YAML.safe_load(ERB.new(ch_config_file.read).result, aliases: true)[Rails.env]
          end
main = ch_yaml&.dig('main') || {}

raw_url = ENV.fetch('CLICKHOUSE_URL', main['url'] || 'http://localhost:8123')
uri = URI.parse(raw_url)
database = ENV.fetch('CLICKHOUSE_DATABASE') { main['database'] || "grovs_#{Rails.env}" }

ClickHouse::Client.configure do |config|
  config.register_database(:main,
    database: database,
    url: "#{uri.scheme}://#{uri.host}:#{uri.port || 8123}",
    username: (uri.user ? URI::DEFAULT_PARSER.unescape(uri.user) : nil) || main['username'] || 'default',
    password: (uri.password ? URI::DEFAULT_PARSER.unescape(uri.password) : nil) || main['password'] || '',
    variables: (main['variables'] || {}).symbolize_keys
  )

  config.json_parser = JSON
  config.logger = Rails.logger
  config.log_proc = Clickhouse::LOG_PROC
  config.http_post_proc = Clickhouse.build_http_post_proc
end

# Feature flags.
Rails.application.config.clickhouse_write_enabled =
  ActiveModel::Type::Boolean.new.cast(ENV.fetch('CLICKHOUSE_WRITE_ENABLED', false))
Rails.application.config.clickhouse_read_enabled =
  ActiveModel::Type::Boolean.new.cast(ENV.fetch('CLICKHOUSE_READ_ENABLED', false))
Rails.application.config.clickhouse_primary = Clickhouse.primary_allowed?(
  primary: ActiveModel::Type::Boolean.new.cast(ENV.fetch('CLICKHOUSE_PRIMARY', false)),
  write: Rails.application.config.clickhouse_write_enabled,
  read: Rails.application.config.clickhouse_read_enabled
)
Rails.application.config.clickhouse_analytics_rollups_read_enabled =
  ActiveModel::Type::Boolean.new.cast(ENV.fetch('CLICKHOUSE_ANALYTICS_ROLLUPS_READ_ENABLED', false))
Rails.application.config.clickhouse_attribution_read_enabled =
  ActiveModel::Type::Boolean.new.cast(ENV.fetch('CLICKHOUSE_ATTRIBUTION_READ_ENABLED', false))
Rails.application.config.clickhouse_link_dimensions_read_enabled =
  ActiveModel::Type::Boolean.new.cast(ENV.fetch('CLICKHOUSE_LINK_DIMENSIONS_READ_ENABLED', false))

# after_initialize: ProjectService is autoloadable here, not during initializer load.
Rails.application.config.after_initialize do
  Clickhouse.validate_shadow_writes_wiring!(
    primary: Clickhouse.primary?,
    shadow_writes: Grovs.pg_shadow_writes?
  )
  Clickhouse.validate_link_dimensions_wiring!(
    reads: Clickhouse.link_dimensions_read_enabled?,
    writes: Clickhouse.enabled?,
    ch_reads: Clickhouse.read_enabled?
  )
  Clickhouse.validate_analytics_reads_wiring!(
    reads: Rails.application.config.clickhouse_analytics_rollups_read_enabled ||
           Rails.application.config.clickhouse_attribution_read_enabled,
    writes: Clickhouse.enabled?,
    ch_reads: Clickhouse.read_enabled?
  )
  Clickhouse.validate_primary_billing_wiring!(
    primary: Clickhouse.primary?,
    self_hosted: Grovs.self_hosted?,
    mau_source: ProjectService::MAU_SOURCE
  )
end
