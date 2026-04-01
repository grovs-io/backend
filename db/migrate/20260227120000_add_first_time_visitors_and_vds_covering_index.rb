class AddFirstTimeVisitorsAndVdsCoveringIndex < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def change
    unless column_exists?(:daily_project_metrics, :first_time_visitors)
      add_column :daily_project_metrics, :first_time_visitors, :integer, default: 0, null: false
    end

    unless index_exists?(:visitor_daily_statistics, [:project_id, :event_date, :visitor_id], name: "idx_vds_project_date_visitor")
      add_index :visitor_daily_statistics,
                [:project_id, :event_date, :visitor_id],
                name: "idx_vds_project_date_visitor",
                algorithm: :concurrently
    end
  end
end
