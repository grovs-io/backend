class DropLinkIdFkFromLinkDailyStatistics < ActiveRecord::Migration[7.0]
  def change
    remove_foreign_key :link_daily_statistics, column: :link_id
  end
end
