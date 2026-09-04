# frozen_string_literal: true

# Phase 5 — exact per-day visitor breakdown by TIME-VARYING dimensions
# (version / country / platform). A visitor's country, app_version or platform can
# change over time, so these are NOT folded into the immutable visitor_acquisition;
# they keep their OWN per-day definition: a visitor is counted in whatever value they
# carried on each day they were active.
#
# Exact via uniqExactState (NOT the approximate `uniq` of the older MV-fed
# project_country_daily/project_version_daily). Rebuilt from the DEDUPED
# events_canonical (FINAL) with the identity map applied BEFORE aggregation, so
# duplicates never inflate and merged visitors count once under the survivor.
#
# Generic (dimension, value) shape so one table + one rebuild path covers all three;
# a date-ranged read does `uniqExactMerge(visitors_state) GROUP BY value` filtered to
# the dimension — exact distinct visitors per value over the range.
class CreateVisitorDimensionDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS visitor_dimension_daily (
          project_id      UInt64,
          event_date      Date,
          dimension       LowCardinality(String),
          value           String,
          visitors_state  AggregateFunction(uniqExact, UInt64)
      )
      ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, event_date, dimension, value)
      SETTINGS index_granularity = 8192
    SQL
  end
end
