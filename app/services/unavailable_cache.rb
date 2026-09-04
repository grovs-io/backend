# frozen_string_literal: true

# Replays a store-unavailable failure briefly so a 503 costs one query, not one per client.
module UnavailableCache
  ERRORS = {
    "revenue" => RevenueLedger::Unavailable,
    "clickhouse" => Clickhouse::Unavailable,
    "rollups_stale" => Clickhouse::Stale
  }.freeze

  def self.fetch(key, ttl:)
    value = Rails.cache.fetch(key, expires_in: ttl) do
      yield
    rescue *ERRORS.values => e
      write_marker(key, e)
      raise
    end
    return value unless value.is_a?(Hash) && value[:unavailable]

    raise ERRORS.fetch(value[:unavailable]), value[:surface].to_s
  end

  def self.write_marker(key, error)
    name = ERRORS.find { |_, klass| error.instance_of?(klass) }&.first
    return unless name

    Rails.cache.write(key, { unavailable: name, surface: error.message },
                      expires_in: RevenueLedger::DEGRADED_CACHE_TTL)
  end
  private_class_method :write_marker
end
