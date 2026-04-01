class DropOldIntegerColumns < ActiveRecord::Migration[7.0]
  def up
    execute "DROP TRIGGER IF EXISTS trg_sync_vds_time_spent_reverse ON visitor_daily_statistics"
    execute "DROP FUNCTION IF EXISTS sync_vds_time_spent_reverse()"
    remove_column :visitor_daily_statistics, :time_spent_old

    execute "DROP TRIGGER IF EXISTS trg_sync_events_engagement_time_reverse ON events"
    execute "DROP FUNCTION IF EXISTS sync_events_engagement_time_reverse()"
    remove_column :events, :engagement_time_old
  end

  def down
    add_column :visitor_daily_statistics, :time_spent_old, :integer, default: 0
    add_column :events, :engagement_time_old, :integer
  end
end
