class DropPreviousStatisticsIndexes < ActiveRecord::Migration[7.0]
  def change
     remove_index :visitor_daily_statistics, name: "index_visitor_daily_statistics_on_visitor_id_and_event_date"
     remove_index :link_daily_statistics, name: "index_link_daily_statistics_on_link_id_and_event_date"
  end
end
