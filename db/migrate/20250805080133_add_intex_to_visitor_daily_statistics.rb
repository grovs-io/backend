class AddIntexToVisitorDailyStatistics < ActiveRecord::Migration[7.0]
  def change
    add_index :visitor_daily_statistics, [:event_date, :visitor_id], name: "index_visitor_daily_stats_on_event_date_visitor_id"
  end
end
