class AddTabletEnabled < ActiveRecord::Migration[6.1]
  def change
    add_column :ios_configurations, :tablet_enabled, :boolean, default: false
    add_column :android_configurations, :tablet_enabled, :boolean, default: false
    add_column :desktop_configurations, :mac_enabled, :boolean, default: false
    add_column :desktop_configurations, :windows_enabled, :boolean, default: false
  end
end
