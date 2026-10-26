class AddLinksCountToSmartBanners < ActiveRecord::Migration[8.1]
  def up
    add_column :smart_banners, :links_count, :integer, null: false, default: 0
    execute <<~SQL
      UPDATE smart_banners SET links_count = counts.n
      FROM (SELECT smart_banner_id, COUNT(*) AS n FROM smart_banner_links GROUP BY smart_banner_id) counts
      WHERE counts.smart_banner_id = smart_banners.id
    SQL
  end

  def down
    remove_column :smart_banners, :links_count
  end
end
