class AddUniqueActiveCustomHostnamePerProject < ActiveRecord::Migration[8.1]
  def change
    # At most one non-removed custom hostname per project, enforced at the DB level
    # so concurrent provisioning requests cannot create two.
    add_index :custom_hostnames, :project_id, unique: true,
              where: "status != 'removed'",
              name: "index_custom_hostnames_one_active_per_project"
  end
end
