# frozen_string_literal: true

class AddUuidToUserProfiles < Clickhouse::Migration
  def up
    execute <<~SQL
      ALTER TABLE user_profiles
        ADD COLUMN IF NOT EXISTS uuid String DEFAULT ''
    SQL
  end
end
