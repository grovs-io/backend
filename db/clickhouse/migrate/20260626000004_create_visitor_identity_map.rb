# frozen_string_literal: true

# Phase 4 — visitor identity map (merged -> survivor), per project.
#
# Records that `from_visitor_id` was merged INTO `to_visitor_id`. The map is kept
# FLAT / path-compressed by ClickhouseIdentityMapService: a chain A->B->C is
# stored as A->C and B->C (never A->B), so a lookup never needs recursive chasing.
#
# ReplacingMergeTree(updated_at) keyed on (project_id, from_visitor_id): re-recording
# the same merge, or repointing a survivor during path compression, collapses to the
# single latest row (highest updated_at) — recording is idempotent + retry-safe.
#
# Applied BEFORE aggregation by ClickhouseRollupRebuildService.effective_visitor_id_expr
# so a merged visitor's pre-merge canonical rows roll up under the survivor and are
# never double-counted. Canonical events are NEVER mutated (Phase 1/2 determinism) —
# the survivor's rollup partitions are simply recomputed with the alias applied.
class CreateVisitorIdentityMap < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS visitor_identity_map (
          project_id      UInt64,
          from_visitor_id UInt64,
          to_visitor_id   UInt64,
          updated_at      DateTime64(3, 'UTC') DEFAULT now64(3)
      )
      ENGINE = ReplacingMergeTree(updated_at)
      ORDER BY (project_id, from_visitor_id)
      SETTINGS index_granularity = 8192
    SQL
  end
end
