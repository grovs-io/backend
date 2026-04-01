class AddBigintShadowColumnsForTimeSpentAndEngagementTime < ActiveRecord::Migration[7.0]
  def up
    # Add shadow bigint columns (instant, metadata-only in PG)
    execute "ALTER TABLE visitor_daily_statistics ADD COLUMN time_spent_big bigint DEFAULT 0 NOT NULL"
    execute "ALTER TABLE events ADD COLUMN engagement_time_big bigint"

    # Trigger: sync visitor_daily_statistics.time_spent -> time_spent_big
    execute <<~SQL
      CREATE OR REPLACE FUNCTION sync_vds_time_spent_big()
      RETURNS trigger AS $$
      BEGIN
        NEW.time_spent_big := NEW.time_spent;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<~SQL
      CREATE TRIGGER trg_sync_vds_time_spent_big
      BEFORE INSERT OR UPDATE OF time_spent ON visitor_daily_statistics
      FOR EACH ROW
      EXECUTE FUNCTION sync_vds_time_spent_big();
    SQL

    # Trigger: sync events.engagement_time -> engagement_time_big
    execute <<~SQL
      CREATE OR REPLACE FUNCTION sync_events_engagement_time_big()
      RETURNS trigger AS $$
      BEGIN
        NEW.engagement_time_big := NEW.engagement_time;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<~SQL
      CREATE TRIGGER trg_sync_events_engagement_time_big
      BEFORE INSERT OR UPDATE OF engagement_time ON events
      FOR EACH ROW
      EXECUTE FUNCTION sync_events_engagement_time_big();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS trg_sync_events_engagement_time_big ON events"
    execute "DROP FUNCTION IF EXISTS sync_events_engagement_time_big()"
    execute "DROP TRIGGER IF EXISTS trg_sync_vds_time_spent_big ON visitor_daily_statistics"
    execute "DROP FUNCTION IF EXISTS sync_vds_time_spent_big()"
    remove_column :events, :engagement_time_big
    remove_column :visitor_daily_statistics, :time_spent_big
  end
end
