class AddMoreFieldsToNotifications < ActiveRecord::Migration[7.0]
  def change
    add_reference :notifications, :visitor, null: false, foreign_key: true
    add_column :notifications, :read, :boolean, default: false
  end
end
