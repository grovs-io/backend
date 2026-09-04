# frozen_string_literal: true

# Phase 5 — per-visitor acquisition (install + first-touch, immutable as-of any range).
#
# One row per (project, effective_visitor) summarising that visitor's WHOLE history:
#   install_source     — source of the EARLIEST install/reinstall (tie-break (created_at, event_id))
#   first_touch_source — source of the EARLIEST link-touch
#   has_install / has_link — presence flags
#   install_ts / first_ts  — the earliest timestamps
#
# PRODUCT / ANALYTICS DESIGN NOTE (confirm before Phase 6 cutover): "link touch" /
# first_touch_source / has_link COUNT campaigns AND sdk-referrals as touches EVEN WHEN
# link_id = 0 — the touch predicate is `Analytics::SourceTaxonomy source != 'organic'`,
# NOT `link_id > 0`. A campaign 'view' with campaign_id>0 and link_id=0 is a real
# attributable first touch. This matches the existing source dashboards; if ANALYTICS
# want a stricter materialized-link definition, the has_link column and
# ClickhouseRollupRebuildService.has_link_predicate must change together.
#
# AS-OF CONTRACT: install_source/first_touch_source are immutable to FUTURE events
# (argMin over the EARLIEST touch — a later-dated event never displaces them). A late
# event DATED BEFORE the current earliest WOULD legitimately change them (correct as-of).
#
# AggregatingMergeTree, UNPARTITIONED, ORDER BY (project_id, visitor_id): acquisition is
# a whole-history per-visitor fact, not a daily slice, so it is keyed by the visitor only.
# The states (argMin/min/max) are idempotent set-merges, so re-inserting a visitor's
# recomputed FULL-history state is safe (merge of two complete states = the complete state)
# — this is how ClickhouseRollupRebuildService bounds the rebuild to touched visitors without
# an ALTER DELETE mutation.
#
# Read with GROUP BY (project_id, visitor_id) + argMinMerge/maxMerge (NOT bare FINAL):
#   resolved = if(has_install, install_source, if(has_link, first_touch_source, 'organic')).
#
# Built from DEDUPED events_canonical (FINAL) with the visitor identity map applied BEFORE
# aggregation (effective_visitor_id), so merged visitors attribute under the survivor and the
# survivor keeps its EARLIEST install_source.
class CreateVisitorAcquisition < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS visitor_acquisition (
          project_id          UInt64,
          visitor_id          UInt64,
          install_source      AggregateFunction(argMinIf, LowCardinality(String), Tuple(DateTime64(3, 'UTC'), String), UInt8),
          first_touch_source  AggregateFunction(argMinIf, LowCardinality(String), Tuple(DateTime64(3, 'UTC'), String), UInt8),
          has_install         AggregateFunction(maxIf, UInt8, UInt8),
          has_link            AggregateFunction(maxIf, UInt8, UInt8),
          install_ts          AggregateFunction(minIf, DateTime64(3, 'UTC'), UInt8),
          first_ts            AggregateFunction(minIf, DateTime64(3, 'UTC'), UInt8)
      )
      ENGINE = AggregatingMergeTree()
      ORDER BY (project_id, visitor_id)
      SETTINGS index_granularity = 8192
    SQL
  end
end
