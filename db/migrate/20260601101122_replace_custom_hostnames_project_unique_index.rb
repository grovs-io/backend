class ReplaceCustomHostnamesProjectUniqueIndex < ActiveRecord::Migration[8.1]
  # Swap unique(project_id) for unique(project_id, purpose) so a project can hold both
  # primary and migration purposes.
  disable_ddl_transaction!

  def up
    remove_index :custom_hostnames, name: "index_custom_hostnames_on_project_id",
                 algorithm: :concurrently, if_exists: true
    add_index :custom_hostnames, [:project_id, :purpose], unique: true,
              name: "index_custom_hostnames_on_project_id_and_purpose",
              algorithm: :concurrently, if_not_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Reversing this migration is unsafe once any project holds both " \
          "primary and migration purposes — would violate the restored " \
          "unique(project_id) constraint. If you really need to roll back, " \
          "first delete one purpose per project, then drop the composite " \
          "and recreate the original index manually."
  end
end
