# frozen_string_literal: true

class CreateMvProjectCountryDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_project_country_daily TO project_country_daily AS
      SELECT
          project_id,
          toDate(created_at) AS event_date,
          country,
          event_type,
          platform,
          count()               AS cnt,
          uniqState(visitor_id) AS visitors_state
      FROM events
      GROUP BY project_id, event_date, country, event_type, platform
    SQL
  end
end
