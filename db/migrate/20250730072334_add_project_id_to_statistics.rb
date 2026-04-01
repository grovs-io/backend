class AddProjectIdToStatistics < ActiveRecord::Migration[7.0]
  def change
    add_column :visitor_daily_statistics, :project_id, :integer
    add_column :link_daily_statistics, :project_id, :integer
  end
end
