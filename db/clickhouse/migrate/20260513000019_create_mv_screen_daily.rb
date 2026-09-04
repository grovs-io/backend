# frozen_string_literal: true

class CreateMvScreenDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_screen_daily TO screen_daily AS
      SELECT
          project_id,
          screen_name,
          event_date,
          platform,
          uniqState(visitor_id)    AS visitors_state,
          count()                  AS total_views,
          sum(engagement_time)     AS total_time_ms
      FROM session_events
      WHERE screen_name != ''
      GROUP BY project_id, screen_name, event_date, platform
    SQL
  end
end
