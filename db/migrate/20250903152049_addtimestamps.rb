class Addtimestamps < ActiveRecord::Migration[7.0]
  def change
     add_timestamps :visitor_daily_statistics, default: -> { 'CURRENT_TIMESTAMP' }, null: false
  end
end
