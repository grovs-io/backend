class RemoveApplicationFields < ActiveRecord::Migration[6.1]
  def change
    remove_column :applications, :identifier
    remove_column :applications, :application_key
  end
end
