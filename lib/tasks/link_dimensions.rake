# frozen_string_literal: true

namespace :link_dimensions do
  # Resumable by id: a failure at 90% re-runs with FROM_ID rather than starting over.
  desc "Backfill link_dimensions from Postgres. MUST complete before CLICKHOUSE_LINK_DIMENSIONS_READ_ENABLED."
  task backfill: :environment do
    from_id = ENV["FROM_ID"].to_i
    batch_size = (ENV["BATCH_SIZE"] || 5_000).to_i
    pause = (ENV["SLEEP"] || 0).to_f
    total = 0
    last_id = from_id

    Link.includes(:domain).where("links.id >= ?", from_id).order(:id)
        .find_in_batches(batch_size: batch_size) do |batch|
      total += LinkDimensionSyncService.sync_all(batch)
      last_id = batch.last.id
      puts "link_dimensions: #{total} synced, through id #{last_id}"
      sleep pause if pause.positive?
    end

    puts "link_dimensions: done, #{total} rows (resume with FROM_ID=#{last_id + 1})"
  end

  # Membership repair (tombstones, id diff, attribute sweep) lives in ReconcileLinkDimensionsJob.
  desc "Re-sync links updated in the last N hours (default 24). Replays writes only — no tombstones."
  task :resync_recent, [:hours] => :environment do |_t, args|
    since = (args[:hours] || 24).to_i.hours.ago
    total = 0
    Link.includes(:domain).where(updated_at: since..).find_in_batches(batch_size: 5_000) do |batch|
      total += LinkDimensionSyncService.sync_all(batch)
    end
    puts "link_dimensions: re-synced #{total} rows since #{since}"
  end
end
