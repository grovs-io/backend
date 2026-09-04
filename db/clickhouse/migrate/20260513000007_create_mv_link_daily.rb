# frozen_string_literal: true

class CreateMvLinkDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_link_daily TO link_daily AS
      SELECT
          project_id,
          link_id,
          campaign_id,
          toDate(created_at) AS event_date,
          event_type,
          platform,
          count()              AS cnt,
          sum(engagement_time) AS total_engagement_time
      FROM events
      WHERE link_id != 0
      GROUP BY project_id, link_id, campaign_id, event_date, event_type, platform
    SQL
  end
end
