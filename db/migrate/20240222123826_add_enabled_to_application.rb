class AddEnabledToApplication < ActiveRecord::Migration[6.1]
  def change
    add_column :applications, :enabled, :boolean, default: true
  end
end
