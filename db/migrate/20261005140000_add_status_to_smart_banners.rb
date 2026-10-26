class AddStatusToSmartBanners < ActiveRecord::Migration[8.1]
  def up
    add_column :smart_banners, :status, :string, null: false, default: "draft"
    execute "UPDATE smart_banners SET status = CASE WHEN active THEN 'live' ELSE 'paused' END"
    remove_column :smart_banners, :active
    add_index :smart_banners, [:project_id, :status]
  end

  def down
    add_column :smart_banners, :active, :boolean, null: false, default: true
    execute "UPDATE smart_banners SET active = (status = 'live')"
    remove_index :smart_banners, [:project_id, :status]
    remove_column :smart_banners, :status
  end
end
