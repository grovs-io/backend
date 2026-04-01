class AddIndexesToStatistics < ActiveRecord::Migration[7.0]
  def change
    add_index :link_daily_statistics,
              [:project_id, :link_id, :event_date],
              unique: true,
              name: 'index_link_daily_stats_on_project_link_date'

    add_index :visitor_daily_statistics,
              [:project_id, :visitor_id, :event_date],
              unique: true,
              name: 'index_visitor_daily_stats_on_project_visitor_date'
  end
end
