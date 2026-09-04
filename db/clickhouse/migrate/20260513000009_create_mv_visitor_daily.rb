# frozen_string_literal: true

class CreateMvVisitorDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_visitor_daily TO visitor_daily AS
      SELECT
          project_id,
          visitor_id,
          toDate(created_at) AS event_date,
          event_type,
          platform,
          count()                  AS cnt,
          sum(engagement_time)     AS total_engagement_time,
          max(inviter_id)          AS inviter_id_state
      FROM events
      GROUP BY project_id, visitor_id, event_date, event_type, platform
    SQL
  end
end
