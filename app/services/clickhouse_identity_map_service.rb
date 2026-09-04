# frozen_string_literal: true

# Phase 4 — visitor identity map (merged -> survivor), per project, in ClickHouse.
#
# Records that `from_visitor_id` was merged INTO `to_visitor_id`, keeping the map
# FLAT / path-compressed so a chain A->B->C is stored as A->C and B->C (never
# A->B). Lookups therefore never need recursive chasing — a single FINAL read
# resolves to the final survivor.
#
# The map is applied BEFORE aggregation by
# ClickhouseRollupRebuildService.effective_visitor_id_expr, so a merged visitor's
# pre-merge canonical rows roll up under the survivor (counted once, under the
# survivor) and are never double-counted. Canonical events are NEVER mutated.
#
# Idempotent + retry-safe: the table is ReplacingMergeTree(updated_at) keyed on
# (project_id, from_visitor_id), so re-recording the same merge (or repointing a
# survivor during path compression) collapses to the single latest row.
#
# RAISES on a ClickHouse failure (NOT fire-and-forget): the durable alias is a
# truth-store requirement, so the caller — MergeVisitorClickhouseFoldJob — must be
# able to retry. The PG merge already committed before this runs, so propagating
# is safe and the idempotency above makes the retry a no-op once it succeeds.
module ClickhouseIdentityMapService
  TABLE = "visitor_identity_map"

  # Record that `from_visitor_id` was merged into `to_visitor_id`.
  #   1. Resolve `to` through the existing map (the survivor itself may have been
  #      merged away earlier — A->B where B already ->C means A must end at C).
  #   2. Path-compress: repoint any existing rows whose to_visitor_id == from to
  #      the new (resolved) survivor, so previously-merged visitors don't dangle
  #      behind a now-merged-away intermediary.
  #   3. Upsert the from -> survivor alias.
  def self.record_merge(project_id, from_visitor_id, to_visitor_id)
    return unless Clickhouse.enabled?

    pid = Integer(project_id)
    from = Integer(from_visitor_id)
    to = Integer(to_visitor_id)
    return if from == to

    survivor = resolve(pid, to)
    return if survivor == from # never alias a visitor to itself (cycle guard)

    rows = [{ project_id: pid, from_visitor_id: from, to_visitor_id: survivor }]
    rows.concat(repoint_rows(pid, from, survivor))

    now = Time.current
    # insert_identity_rows swallows CH errors and returns false — turn that into a
    # raise so the fold job retries instead of silently losing the alias. resolve/
    # repoint above raise on their own CH failures, which now propagate too.
    ok = ClickhouseWriteService.insert_identity_rows(rows.map { |r| r.merge(updated_at: now) })
    raise "ClickhouseIdentityMapService: identity-map insert failed for #{from}->#{survivor} in project #{pid}" unless ok
  end

  # Resolve a visitor_id to its current final survivor (or itself if unmapped).
  def self.resolve(project_id, visitor_id)
    resolve_many(project_id, [visitor_id]).fetch(Integer(visitor_id))
  end

  # Batch variant: {input_id => survivor} for every input (itself if unmapped).
  def self.resolve_many(project_id, visitor_ids)
    ids = visitor_ids.map { |v| Integer(v) }.uniq
    return {} if ids.empty?

    map = ids.index_with { |id| id }
    rows = Clickhouse.with do |conn|
      conn.select_all(
        "SELECT from_visitor_id, to_visitor_id FROM #{TABLE} FINAL " \
        "WHERE project_id = #{Integer(project_id)} AND from_visitor_id IN (#{ids.join(', ')})"
      )
    end
    rows.each { |r| map[r["from_visitor_id"].to_i] = r["to_visitor_id"].to_i }
    map
  end

  # Rows whose current survivor is `from` and must now point at the new survivor.
  def self.repoint_rows(project_id, from, survivor)
    existing = Clickhouse.with do |conn|
      conn.select_all(
        "SELECT from_visitor_id FROM #{TABLE} FINAL " \
        "WHERE project_id = #{Integer(project_id)} AND to_visitor_id = #{Integer(from)}"
      )
    end
    existing.map do |r|
      { project_id: project_id, from_visitor_id: r["from_visitor_id"].to_i, to_visitor_id: survivor }
    end
  end
  private_class_method :repoint_rows
end
