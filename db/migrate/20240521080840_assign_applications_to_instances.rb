class AssignApplicationsToInstances < ActiveRecord::Migration[6.1]
  def change
    remove_column :applications, :project_id
    add_reference :applications, :instance, foreign_key: true
  end
end
