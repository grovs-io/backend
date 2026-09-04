# frozen_string_literal: true

# An unrebuilt rollup partition answers 0 rows, not nil, so only a freshness stamp catches it.
module ClickhouseRollupLiveness
  KEY_PREFIX = "clickhouse:rollup_liveness"
  LANES = %i[fast full].freeze
  # Long TTL so the normal stale signal is an OLD stamp, not a missing one.
  KEY_TTL = 7.days.to_i

  class << self
    # Permissive: the full lane runs every 10 min, so this only trips when every lane is dead.
    def max_age_seconds
      Integer(ENV.fetch("CLICKHOUSE_ROLLUP_MAX_AGE_SECONDS", 1800))
    end

    def record(lane)
      REDIS.with { |conn| conn.set(key(lane), Time.current.to_i, ex: KEY_TTL) }
    rescue StandardError => e
      Rails.logger.warn("ClickhouseRollupLiveness: #{lane} lane stamp failed — #{e.class}: #{e.message}")
    end

    def gate!(query)
      return unless Clickhouse.primary?

      sql = query.respond_to?(:to_sql) ? query.to_sql : query.to_s
      return unless rollup_sql?(sql)
      return if fresh?

      Grovs::Metrics.increment("clickhouse.rollups.stale")
      raise Clickhouse::Stale, "no rollup rebuild lane succeeded in the last #{max_age_seconds}s"
    end

    # Only "no ENABLED lane succeeded" is fatal — a disabled lane's stamp would mask the other.
    def fresh?
      cutoff = Time.current.to_i - max_age_seconds
      keys = LANES.select { |lane| lane_enabled?(lane) }.map { |lane| key(lane) }
      stamps = REDIS.with { |conn| conn.mget(*keys) }
      stamps.compact.any? { |at| at.to_i > cutoff }
    rescue StandardError => e
      # The gate exists to catch a dead rebuild job, not to police Redis.
      Rails.logger.warn("ClickhouseRollupLiveness: freshness read failed — #{e.class}: #{e.message}")
      true
    end

    def key(lane)
      "#{KEY_PREFIX}:#{lane}"
    end

    def lane_enabled?(lane)
      lane == :full || ClickhouseRollupRebuildService.fast_lane_enabled?
    end

    def clear!
      REDIS.with { |conn| conn.del(*LANES.map { |lane| key(lane) }) }
    end

    def rollup_sql?(sql)
      sql.match?(rollup_table_regexp)
    end

    private

    # Only the rebuild's own tables — events/session_summary reads stay live, so never gated.
    def rollup_table_regexp
      @rollup_table_regexp ||= begin
        tables = ClickhouseRollupRebuildService::ROLLUPS.each_value.map { |config| config[:table] } +
                 [ClickhouseRollupRebuildService::ACQUISITION_TABLE]
        /\b(?:FROM|JOIN)\s+`?(?:#{Regexp.union(tables).source})`?\b/i
      end
    end
  end
end
