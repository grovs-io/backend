class AddFieldsToDesktopConfig < ActiveRecord::Migration[6.1]
  def change
    add_column :desktop_configurations, :generated_page, :boolean, default: true
    add_column :desktop_configurations, :fallback_url, :string
    add_column :desktop_configurations, :mac_uri, :string
    add_column :desktop_configurations, :windows_uri, :string
  end
end
