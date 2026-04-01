class AddDeviceToVisitors < ActiveRecord::Migration[7.0]
  def change
    remove_column :devices, :visitor_id
    add_reference :visitors, :device, null: false, foreign_key: true
  end
end
