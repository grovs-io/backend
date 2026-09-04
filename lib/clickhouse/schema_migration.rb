# frozen_string_literal: true

module Clickhouse
  class SchemaMigration
    TABLE_NAME = 'schema_migrations'

    def initialize(connection)
      @connection = connection
    end

    def ensure_table
      @connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{TABLE_NAME} (
          version LowCardinality(String),
          applied_at DateTime64(6, 'UTC') DEFAULT now64()
        )
        ENGINE = ReplacingMergeTree(applied_at)
        ORDER BY (version)
      SQL
    end

    def all_versions
      @connection.select_all(
        "SELECT version FROM #{TABLE_NAME} FINAL ORDER BY version"
      ).map { |row| row['version'].to_i }
    end

    def record_version(version)
      @connection.insert(TABLE_NAME, [{ 'version' => version.to_s }])
    end
  end
end
