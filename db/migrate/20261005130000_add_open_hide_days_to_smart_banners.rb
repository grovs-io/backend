class AddOpenHideDaysToSmartBanners < ActiveRecord::Migration[8.1]
  def change
    add_column :smart_banners, :open_hide_days, :integer, null: false, default: 30
  end
end
