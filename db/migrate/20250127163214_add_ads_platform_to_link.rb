class AddAdsPlatformToLink < ActiveRecord::Migration[7.0]
  def change
    add_column :links, :ads_platform, :string
  end
end
