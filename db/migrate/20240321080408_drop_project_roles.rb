class DropProjectRoles < ActiveRecord::Migration[6.1]
  def change
    drop_table :project_roles
  end
end
