class AddSubtleToTheNotification < ActiveRecord::Migration[7.0]
  def change
    add_column :notifications, :subtitle, :string
  end
end
