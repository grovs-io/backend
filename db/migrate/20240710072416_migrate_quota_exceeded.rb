class MigrateQuotaExceeded < ActiveRecord::Migration[6.1]
  def change
    remove_column :projects, :quota_exceeded, :boolean
    add_column :instances, :quota_exceeded, :boolean, default: false
  end
end
