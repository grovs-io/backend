class HardenCustomHostnames < ActiveRecord::Migration[8.1]
  # P3.6: add DB-level foreign keys (app-level dependent: :destroy already cascades,
  # but enforce referential integrity at the DB too, for consistency with the rest of
  # the schema). P3.7: teardown hard-deletes rows (no "removed" tombstone), so the
  # partial "status != 'removed'" predicate is dead; collapse it and the redundant
  # non-unique project_id index into a single unique index (one custom hostname per
  # project).
  def up
    add_foreign_key :custom_hostnames, :projects unless foreign_key_exists?(:custom_hostnames, :projects)
    add_foreign_key :custom_hostnames, :domains  unless foreign_key_exists?(:custom_hostnames, :domains)

    remove_index :custom_hostnames, name: "index_custom_hostnames_one_active_per_project" if index_name_exists?(:custom_hostnames, "index_custom_hostnames_one_active_per_project")
    remove_index :custom_hostnames, name: "index_custom_hostnames_on_project_id" if index_name_exists?(:custom_hostnames, "index_custom_hostnames_on_project_id")
    add_index :custom_hostnames, :project_id, unique: true, name: "index_custom_hostnames_on_project_id"
  end

  def down
    remove_index :custom_hostnames, name: "index_custom_hostnames_on_project_id" if index_name_exists?(:custom_hostnames, "index_custom_hostnames_on_project_id")
    add_index :custom_hostnames, :project_id, name: "index_custom_hostnames_on_project_id"
    add_index :custom_hostnames, :project_id, unique: true,
              where: "status != 'removed'", name: "index_custom_hostnames_one_active_per_project"

    remove_foreign_key :custom_hostnames, :domains  if foreign_key_exists?(:custom_hostnames, :domains)
    remove_foreign_key :custom_hostnames, :projects if foreign_key_exists?(:custom_hostnames, :projects)
  end
end
