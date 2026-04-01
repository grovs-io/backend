class AddArchivedFlagToNotifications < ActiveRecord::Migration[7.0]
  def change
    add_column :notifications, :archived, :boolean, default: false
  end
end
