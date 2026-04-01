class SwapBigintColumns < ActiveRecord::Migration[7.0]
  def up
    # --- visitor_daily_statistics ---
    execute "DROP TRIGGER IF EXISTS trg_sync_vds_time_spent_big ON visitor_daily_statistics"
    execute "DROP FUNCTION IF EXISTS sync_vds_time_spent_big()"
    execute "ALTER TABLE visitor_daily_statistics RENAME COLUMN time_spent TO time_spent_old"
    execute "ALTER TABLE visitor_daily_statistics RENAME COLUMN time_spent_big TO time_spent"

    # Reverse sync trigger so in-flight code referencing old column still works
    execute <<~SQL
      CREATE OR REPLACE FUNCTION sync_vds_time_spent_reverse()
      RETURNS trigger AS $$
      BEGIN
        NEW.time_spent_old := NEW.time_spent;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
    execute <<~SQL
      CREATE TRIGGER trg_sync_vds_time_spent_reverse
      BEFORE INSERT OR UPDATE OF time_spent ON visitor_daily_statistics
      FOR EACH ROW
      EXECUTE FUNCTION sync_vds_time_spent_reverse();
    SQL

    # --- events ---
    execute "DROP TRIGGER IF EXISTS trg_sync_events_engagement_time_big ON events"
    execute "DROP FUNCTION IF EXISTS sync_events_engagement_time_big()"
    execute "ALTER TABLE events RENAME COLUMN engagement_time TO engagement_time_old"
    execute "ALTER TABLE events RENAME COLUMN engagement_time_big TO engagement_time"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION sync_events_engagement_time_reverse()
      RETURNS trigger AS $$
      BEGIN
        NEW.engagement_time_old := NEW.engagement_time;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
    execute <<~SQL
      CREATE TRIGGER trg_sync_events_engagement_time_reverse
      BEFORE INSERT OR UPDATE OF engagement_time ON events
      FOR EACH ROW
      EXECUTE FUNCTION sync_events_engagement_time_reverse();
    SQL
  end

  def down
    # --- events ---
    execute "DROP TRIGGER IF EXISTS trg_sync_events_engagement_time_reverse ON events"
    execute "DROP FUNCTION IF EXISTS sync_events_engagement_time_reverse()"
    execute "ALTER TABLE events RENAME COLUMN engagement_time TO engagement_time_big"
    execute "ALTER TABLE events RENAME COLUMN engagement_time_old TO engagement_time"

    # --- visitor_daily_statistics ---
    execute "DROP TRIGGER IF EXISTS trg_sync_vds_time_spent_reverse ON visitor_daily_statistics"
    execute "DROP FUNCTION IF EXISTS sync_vds_time_spent_reverse()"
    execute "ALTER TABLE visitor_daily_statistics RENAME COLUMN time_spent TO time_spent_big"
    execute "ALTER TABLE visitor_daily_statistics RENAME COLUMN time_spent_old TO time_spent"
  end
end
