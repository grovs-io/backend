class AddIndexToVendorOnDevices < ActiveRecord::Migration[7.0]
  def change
    
    unless index_exists?(:devices, :vendor)
      add_index :devices, :vendor
    end

    unless index_exists?(:events, [:project_id, :device_id, :created_at])
      add_index :events, [:project_id, :device_id, :created_at]
    end
  end
end
