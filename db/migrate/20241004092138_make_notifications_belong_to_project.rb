class MakeNotificationsBelongToProject < ActiveRecord::Migration[7.0]
  def change
    add_reference :notifications, :project, foreign_key: true
  end
end
