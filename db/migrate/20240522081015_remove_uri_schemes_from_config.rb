class RemoveUriSchemesFromConfig < ActiveRecord::Migration[6.1]
  def change
    remove_column :ios_configurations, :uri_scheme
    remove_column :ios_configurations, :tablet_uri_scheme
    remove_column :android_configurations, :uri_scheme
    remove_column :android_configurations, :tablet_uri_scheme
  end
end
