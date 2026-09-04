# frozen_string_literal: true

class CreateUserProfiles < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS user_profiles (
          project_id      UInt64,
          visitor_id      UInt64,
          sdk_identifier  String DEFAULT '',
          properties      JSON,
          first_seen      DateTime64(3, 'UTC'),
          last_seen       DateTime64(3, 'UTC'),
          country         LowCardinality(String) DEFAULT '',
          platform        LowCardinality(String) DEFAULT '',
          inviter_id      UInt64 DEFAULT 0
      )
      ENGINE = ReplacingMergeTree(last_seen)
      ORDER BY (project_id, visitor_id)
      SETTINGS index_granularity = 8192
    SQL
  end
end
