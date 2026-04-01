class RenameQuotaExceeded < ActiveRecord::Migration[6.1]
  def change
    remove_column :projects, :quota_exceeded_date
    add_column :projects, :quota_exceeded, :boolean, default: false
  end
end
