class AddPurposeToCustomHostnames < ActiveRecord::Migration[8.1]
  # CHECK constraint forces app constants, validator, and DB to stay in sync
  # (mirrors migration_sources_provider_check).
  def change
    add_column :custom_hostnames, :purpose, :string, null: false, default: "primary"

    add_check_constraint :custom_hostnames,
      "purpose IN ('primary','migration')",
      name: "custom_hostnames_purpose_check"
  end
end
