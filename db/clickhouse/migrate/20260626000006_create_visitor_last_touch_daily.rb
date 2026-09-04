# frozen_string_literal: true

# Phase 5 — last-touch-source daily snapshot (per project / effective-visitor / day).
#
# Each row holds the last link-touch source OF THAT DAY (argMaxIf over (created_at, event_id)
# where the event is non-organic per Analytics::SourceTaxonomy — campaigns & sdk-referrals
# count even with link_id = 0). The "as-of a range" answer is computed at read time:
# argMaxMerge over all rows with event_date <= range_end yields the last link-touch source up
# to the range end.
#
# AS-OF CONTRACT (precise — NOT "past days never change"): a date-ranged last-touch answer is
# a function of every event DATED within/up-to the range end. So an event DATED AFTER the
# range end NEVER changes that range's answer (it only adds NEW snapshot days beyond it). But
# an event DATED INSIDE a past range — a late delivery landing on an in-range day — DOES
# change that range's answer, which is the CORRECT as-of result (we now know a later in-range
# touch). The recompute of a touched day's row is deterministic (canonical is immutable;
# the survivor's partition recomputes identically), so re-running the same query over the
# same DATED events is byte-stable.
#
# This avoids a per-query full-canonical scan: the as-of read touches only this small daily
# snapshot, bounded by the date range.
#
# AggregatingMergeTree PARTITION BY toYYYYMM(event_date) so it rebuilds partition-scoped like
# the other daily rollups. Identity map applied BEFORE aggregation (effective_visitor_id).
class CreateVisitorLastTouchDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS visitor_last_touch_daily (
          project_id        UInt64,
          visitor_id        UInt64,
          event_date        Date,
          last_touch_source AggregateFunction(argMaxIf, LowCardinality(String), Tuple(DateTime64(3, 'UTC'), String), UInt8),
          last_touch_ts     AggregateFunction(maxIf, DateTime64(3, 'UTC'), UInt8),
          has_link          AggregateFunction(maxIf, UInt8, UInt8)
      )
      ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, visitor_id, event_date)
      SETTINGS index_granularity = 8192
    SQL
  end
end
