class AddIndexToVisitorsStatistics < ActiveRecord::Migration[7.0]
  def change
    add_index :visitor_daily_statistics, :event_date
  end
end
