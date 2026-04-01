class AddVisitorIdToStats < ActiveRecord::Migration[7.0]
  def change
    add_column :visitor_daily_statistics, :invited_by_id, :bigint
    add_index  :visitor_daily_statistics, :invited_by_id
  end
end
