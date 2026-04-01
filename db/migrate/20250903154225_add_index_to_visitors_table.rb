class AddIndexToVisitorsTable < ActiveRecord::Migration[7.0]
  def change
    add_index :visitor_daily_statistics,
                [:project_id, :visitor_id, :event_date, :platform],
                unique: true,
                name: "uniq_vds_proj_visitor_date_platform"
  end
end
