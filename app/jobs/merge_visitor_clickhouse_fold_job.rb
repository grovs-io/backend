# frozen_string_literal: true

# The ClickHouse half of a visitor merge, split out of MergeVisitorEventsJob so it
# can retry INDEPENDENTLY of the PG merge.
#
# Why its own job (not inline + whole-job retry): MergeVisitorEventsJob#merge!
# commits the PG merge and then DELETES the merged visitor. If the fold were inline
# and the whole job retried, merge! would early-return at the "from_visitor not
# found" guard and never re-run the fold — so the alias would be lost forever. As a
# separate job the fold replays via Sidekiq retry until it succeeds; record_merge is
# idempotent (ReplacingMergeTree), so a replay never double-folds.
#
# Durability: record_merge RAISES on a CH failure, so a hiccup re-queues here
# (retry: 10 → Dead set) instead of silently dropping the durable identity-map
# alias. mark_dirty_for_visitor self-rescues (watermark fallback), so it never
# blocks the alias write.
class MergeVisitorClickhouseFoldJob
  include Sidekiq::Job
  sidekiq_options queue: :events, retry: 10

  def perform(project_id, merged_visitor_id, survivor_visitor_id)
    return unless merged_visitor_id && survivor_visitor_id

    ClickhouseIdentityMapService.record_merge(project_id, merged_visitor_id, survivor_visitor_id)
    merged_partitions = ClickhouseRollupRebuildService.mark_dirty_for_visitor(project_id, merged_visitor_id)
    survivor_partitions = ClickhouseRollupRebuildService.mark_dirty_for_visitor(project_id, survivor_visitor_id)
    # Alias is recorded above, so the post-bust re-read is already merge-aware. Trailing
    # 12 months are always busted so a failed partition discovery can't leave an old
    # cached month pre-merge.
    recent = (0..12).map { |i| (Date.current << i).strftime("%Y%m") }
    ProjectService.bust_mau_cache(project_id, Array(merged_partitions) | Array(survivor_partitions) | recent)
    ClickhouseRollupRebuildService.repair_acquisition_for_visitor_merge(
      project_id,
      merged_visitor_id,
      survivor_visitor_id
    )
  end
end
