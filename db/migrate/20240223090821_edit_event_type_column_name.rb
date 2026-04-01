class EditEventTypeColumnName < ActiveRecord::Migration[6.1]
  def change
    rename_column :events, :type, :event
  end
end
