class AddIndexesForDevices < ActiveRecord::Migration[7.0]
  def change
    unless index_exists?(:devices, :ip)
      add_index :devices, :ip
    end

    unless index_exists?(:devices, :remote_ip)
      add_index :devices, :remote_ip
    end

    unless index_exists?(:devices, :updated_at)
      add_index :devices, :updated_at
    end

    unless index_exists?(:devices, :vendor)
      add_index :devices, :vendor
    end
  end
end
