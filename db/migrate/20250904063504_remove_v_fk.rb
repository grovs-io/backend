class RemoveVFk < ActiveRecord::Migration[7.0]
  def change
    remove_foreign_key :visitor_daily_statistics, column: :visitor_id
  end
end
