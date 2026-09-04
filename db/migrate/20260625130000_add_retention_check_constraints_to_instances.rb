class AddRetentionCheckConstraintsToInstances < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :instances, "cold_storage_days > 0",
                         name: "instances_cold_storage_days_positive"
    add_check_constraint :instances, "delete_days >= cold_storage_days",
                         name: "instances_delete_days_gte_cold_storage"
  end
end
