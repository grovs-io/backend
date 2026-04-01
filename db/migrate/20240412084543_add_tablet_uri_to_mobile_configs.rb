class AddTabletUriToMobileConfigs < ActiveRecord::Migration[6.1]
  def change
    add_column :ios_configurations, :tablet_uri_scheme, :string
    add_column :android_configurations, :tablet_uri_scheme, :string
  end
end
