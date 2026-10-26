class AddLockVersionToEventDestinations < ActiveRecord::Migration[8.1]
  def change
    add_column :event_destinations, :lock_version, :integer, null: false, default: 0
  end
end
