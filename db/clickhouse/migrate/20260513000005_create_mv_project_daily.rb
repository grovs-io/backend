# frozen_string_literal: true

class CreateMvProjectDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_project_daily TO project_daily AS
      SELECT
          project_id,
          toDate(created_at) AS event_date,
          event_type,
          platform,
          count()                    AS cnt,
          sum(engagement_time)       AS total_engagement_time,
          uniqState(visitor_id)      AS visitors_state,
          uniqState(device_id)       AS devices_state
      FROM events
      GROUP BY project_id, event_date, event_type, platform
    SQL
  end
end
