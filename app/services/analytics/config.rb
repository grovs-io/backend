# frozen_string_literal: true

module Analytics
  module Config
    def self.int(key, default) = ENV.fetch(key, default.to_s).to_i

    QUERY_MAX_EXECUTION_SEC     = int('ANALYTICS_QUERY_MAX_EXECUTION_SEC', 25)
    QUERY_MAX_MEMORY_BYTES      = int('ANALYTICS_QUERY_MAX_MEMORY_BYTES', 4_000_000_000)
    MAX_PROPERTY_KEYS_PER_EVENT = int('ANALYTICS_MAX_PROPERTY_KEYS_PER_EVENT', 64)
  end
end
