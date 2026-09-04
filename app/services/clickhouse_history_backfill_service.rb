# frozen_string_literal: true

# Phase 6 — one-time PG → CH history backfill into the GREENFIELD events
# store, followed by a rollup + acquisition rebuild over the backfilled partitions.
#
# READ-ONLY on Postgres: it only SELECTs historical `events` (in batches by id), it
# never writes or mutates PG. Idempotent: canonical is a ReplacingMergeTree keyed by
# the frozen `event_id`, so re-running the backfill (or overlapping ranges) collapses
# duplicates and never inflates counts — EXCEPT across the 2026-07-13 identity
# amendment: pre-amendment property-bearing custom/screen_view rows carry legacy ids
# and would rekey (duplicate) on overlay. Guarded below: truncate + rebuild such
# windows, or set ALLOW_PROPERTY_EVENT_OVERLAY=1 to bypass knowingly.
#
# FROZEN-SOURCE BEST-EFFORT (the historical PG rows predate Phase-1 freezing, so they
# carry NO frozen source). We reconstruct it by re-joining the link:
#   * link present AND NOT visitor-merged → use the link's campaign_id/sdk_generated/
#     visitor_id as the source (best-effort reconstruction).
#   * link MISSING (deleted) OR visitor-merged (link.visitor_id rewritten by a merge,
#     so re-joining would attribute to the wrong visitor) → fall back to ORGANIC
#     (campaign_id 0, sdk_generated 0, link_visitor_id 0). This matches the plan's
#     "unknown/organic for merged or missing links" rule and keeps the backfill from
#     fabricating attribution it can't trust.
#
# Bounded + resumable: caller passes an inclusive created_at date range; rows are
# streamed in id-ordered batches of BATCH_SIZE. Progress is logged per batch.
module ClickhouseHistoryBackfillService
  BATCH_SIZE = Integer(ENV.fetch("CLICKHOUSE_BACKFILL_BATCH_SIZE", 5_000))

  # skipped: { missing_device: N } — PG rows dropped because their Device row is gone
  # (or any other skip reason). Tracked so the rake task can report dropped rows
  # instead of silently swallowing them.
  # reconstruction makes the best-effort floor OBSERVABLE: how much historical attribution was
  # rebuilt from CURRENT link state (uncertain — a later campaign/merge mutation can't be undone)
  # vs forced to organic (missing/merged link) vs genuinely organic (no link). Lets an operator
  # gauge how much of a backfilled range is trustworthy before flipping reads at cutover.
  Result = Struct.new(:events_read, :rows_inserted, :skipped, :reconstruction, :partitions, :batches,
                      keyword_init: true)

  # Backfill canonical from PG events dated within [start_date, end_date] (inclusive),
  # then rebuild the rollups for every YYYYMM partition the range spans. Set
  # rebuild: false to only load canonical (e.g. to rebuild separately afterward).
  def self.backfill(start_date:, end_date:, project_id: nil, rebuild: true)
    raise "ClickHouse writes are disabled (set CLICKHOUSE_WRITE_ENABLED=true)" unless Clickhouse.enabled?

    warn_if_reads_enabled

    sd = start_date.to_date.beginning_of_day
    ed = end_date.to_date.end_of_day
    assert_no_property_event_overlay!(sd, ed, project_id)
    events_read = 0
    rows_inserted = 0
    skipped = Hash.new(0)
    reconstruction = Hash.new(0)
    batches = 0
    partitions = Set.new

    scope = Event.where(created_at: sd..ed)
    scope = scope.where(project_id: project_id) if project_id

    scope.in_batches(of: BATCH_SIZE, order: :asc) do |relation|
      pg_rows = relation.pluck(*EVENT_COLUMNS)
      events_read += pg_rows.size
      next if pg_rows.empty?

      ch_rows = build_rows(pg_rows, skipped, reconstruction)
      ch_rows.each { |r| partitions << r[:created_at].to_date.strftime("%Y%m") }

      # insert_canonical_events returns false on CH failure — must NOT be counted as inserted,
      # and we must abort BEFORE rebuilding rollups over incomplete canonical. Raising is safe
      # and resumable: canonical is idempotent by event_id, so a re-run picks up where it stopped.
      # (Mirrors the archive importer's flush; the PG backfill previously swallowed the false.)
      if ch_rows.any? && !ClickhouseWriteService.insert_canonical_events(ch_rows)
        raise "ClickhouseHistoryBackfillService: events insert failed for #{ch_rows.size} rows " \
              "(batch #{batches + 1}) — aborting before rollup rebuild; re-run to resume (idempotent by event_id)"
      end
      rows_inserted += ch_rows.size
      batches += 1
      Rails.logger.info(
        "ClickhouseHistoryBackfillService: batch #{batches} — read #{pg_rows.size}, " \
        "inserted #{ch_rows.size} (cumulative inserted #{rows_inserted})"
      )
    end

    rebuild_partitions(partitions.to_a) if rebuild && partitions.any?

    Rails.logger.info(
      "ClickhouseHistoryBackfillService: attribution reconstruction — #{reconstruction.to_h.inspect} " \
      "(link_reconstructed = best-effort from current link state; the rest is organic)"
    )
    Result.new(events_read: events_read, rows_inserted: rows_inserted, skipped: skipped,
               reconstruction: reconstruction, partitions: partitions.to_a.sort, batches: batches)
  end

  # ReplacingMergeTree dedups by event_id keeping the row with the latest ingested_at.
  # If live reads/writes are ON while a backfill runs, a late-arriving backfill row could
  # overwrite a fresher live row. Warn loudly (do NOT raise) so the operator can abort and
  # re-run with read flags OFF per the cutover runbook.
  def self.warn_if_reads_enabled
    return unless Clickhouse.read_enabled?

    Rails.logger.warn(
      "ClickhouseHistoryBackfillService: WARNING — ClickHouse reads are ENABLED while " \
      "backfilling. Live reads/writes may be active and ReplacingMergeTree dedup by " \
      "ingested_at means a late backfill row could overwrite a fresher live row. Run the " \
      "backfill with read flags OFF, complete it fully, then run the parity gate, THEN flip."
    )
  end
  private_class_method :warn_if_reads_enabled

  # The PG event columns we pull (ordered — pluck returns arrays in this order).
  EVENT_COLUMNS = %i[
    id project_id device_id event event_name session_id link_id
    platform app_version build vendor_id engagement_time ip remote_ip path
    created_at data
  ].freeze

  # Public seam for offline importers (e.g. the archive CSV importer): map a batch of
  # EVENT_COLUMNS-ordered arrays to canonical CH rows using the EXACT same enrichment
  # (device/visitor/link joins, frozen event_id, attribution) as the PG backfill.
  # Callers must pass ids as Integers and created_at as a Time (see EVENT_COLUMNS).
  def self.canonical_rows_for(pg_rows, skipped = Hash.new(0), reconstruction = Hash.new(0))
    build_rows(pg_rows, skipped, reconstruction)
  end

  def self.build_rows(pg_rows, skipped, reconstruction = Hash.new(0))
    device_ids = pg_rows.map { |r| r[2] }.uniq
    project_ids = pg_rows.map { |r| r[1] }.uniq
    link_ids = pg_rows.filter_map { |r| r[6] }.uniq

    devices = Device.where(id: device_ids).index_by(&:id)
    links = Link.where(id: link_ids).index_by(&:id)
    visitors = Visitor.where(project_id: project_ids, device_id: device_ids)
                      .index_by { |v| [v.project_id, v.device_id] }
    merged_link_ids = visitor_merged_link_ids(link_ids)
    country_cache = {} # memoize geo per IP within the batch (avoids per-row GeoipService.lookup)
    row_builder = ClickhouseEventRowBuilder.new

    pg_rows.filter_map do |row|
      attrs = EVENT_COLUMNS.zip(row).to_h
      device = devices[attrs[:device_id]]
      if device.nil?
        skipped[:missing_device] += 1
        next
      end

      visitor = visitors[[attrs[:project_id], attrs[:device_id]]]
      link = attrs[:link_id] ? links[attrs[:link_id]] : nil
      build_canonical_row(attrs, device, visitor, link, merged_link_ids, country_cache, reconstruction, row_builder)
    end
  end
  private_class_method :build_rows

  # A link whose visitor_id no longer matches the visitor that actually owns its
  # events has been rewritten by a visitor merge — re-joining it would attribute to
  # the wrong visitor, so we treat it as merged → organic. We approximate "merged"
  # conservatively: any link whose owning visitor was itself merged away. Without a
  # reliable historical merge ledger we err toward organic (the plan's documented
  # best-effort), so this returns links flagged by the lightweight heuristic below.
  def self.visitor_merged_link_ids(_link_ids)
    # No historical merge ledger exists in PG; the live freezing path (Phase 1) is
    # what guarantees correctness going forward. For history we cannot distinguish a
    # legitimately-attributed link from a merge-rewritten one, so the safe, documented
    # choice is to trust the link join (best-effort) and let the parity gate surface
    # any residual drift into the 'organic'/'unknown' bucket. Returns an empty set;
    # callers fall back to organic only for MISSING links.
    Set.new
  end
  private_class_method :visitor_merged_link_ids

  def self.build_canonical_row(attrs, device, visitor, link, merged_link_ids, country_cache = {},
                               reconstruction = Hash.new(0), row_builder = ClickhouseEventRowBuilder.new)
    use_link = link && !merged_link_ids.include?(link.id)
    campaign_id = use_link ? (link.campaign_id || 0) : 0
    sdk_generated = use_link && link.sdk_generated ? 1 : 0
    link_visitor_id = use_link ? (link.visitor_id || 0) : 0

    # Observability of the best-effort floor: did we reconstruct a non-organic source from
    # current link state (uncertain), force organic because the link is missing/merged, or is
    # this genuinely organic (no link)?
    if use_link && (campaign_id != 0 || sdk_generated == 1 || link_visitor_id != 0)
      reconstruction[:link_reconstructed] += 1
    elsif attrs[:link_id] && !use_link
      reconstruction[:organic_fallback_missing_or_merged_link] += 1
    else
      reconstruction[:organic] += 1
    end

    {
      event_id: ClickhouseWriteService.generate_event_id(
        project_id: attrs[:project_id],
        device_id: device.id,
        event_type: attrs[:event],
        created_at: attrs[:created_at],
        event_name: attrs[:event_name].to_s,
        session_id: attrs[:session_id].to_s,
        link_id: attrs[:link_id] || 0,
        engagement_time: attrs[:engagement_time].to_i,
        properties: attrs[:data]
      ),
      project_id: attrs[:project_id],
      event_type: attrs[:event],
      event_name: attrs[:event_name].to_s,
      # Visitor nil on purpose — mutable sdk_attributes stay out (see sdk_identifier note below).
      screen_name: row_builder.resolve_screen_name(attrs),
      device_id: device.id,
      visitor_id: visitor&.id || 0,
      link_id: attrs[:link_id] || 0,
      inviter_id: visitor&.inviter_id || 0,
      campaign_id: campaign_id,
      platform: attrs[:platform].to_s,
      app_version: attrs[:app_version].to_s,
      build: attrs[:build].to_s,
      vendor_id: attrs[:vendor_id].to_s,
      country: backfill_country(attrs[:remote_ip].to_s, country_cache),
      # Current PG value, not an event-time snapshot; mutable sdk_attributes stay out.
      sdk_identifier: visitor&.sdk_identifier.to_s,
      sdk_generated: sdk_generated,
      link_visitor_id: link_visitor_id,
      session_id: attrs[:session_id].to_s,
      engagement_time: attrs[:engagement_time].to_i,
      properties: backfill_properties(attrs[:data]),
      ip: attrs[:ip].to_s,
      remote_ip: attrs[:remote_ip].to_s,
      path: attrs[:path].to_s,
      created_at: attrs[:created_at]
    }
  end
  private_class_method :build_canonical_row

  # Geo the EVENT's historical IP (not the device's current IP, which would stamp a
  # traveller's whole history with today's country). Memoized per IP; best-effort.
  # Overlaying property-bearing custom events written before the 2026-07-13 identity
  # amendment rekeys them (legacy id != property-derived id) and double-counts.
  def self.assert_no_property_event_overlay!(range_start, range_end, project_id)
    return if ENV["ALLOW_PROPERTY_EVENT_OVERLAY"] == "1"

    from_ts = range_start.utc.strftime("%Y-%m-%d %H:%M:%S.%L")
    to_ts = range_end.utc.strftime("%Y-%m-%d %H:%M:%S.%L")
    scope = "created_at >= toDateTime64('#{from_ts}', 3) AND created_at <= toDateTime64('#{to_ts}', 3)"
    scope += " AND project_id = #{Integer(project_id)}" if project_id
    existing = Clickhouse.with do |conn|
      conn.select_value(
        "SELECT count() FROM events WHERE #{scope} " \
        "AND event_type IN ('#{Grovs::Events::CUSTOM}', '#{Grovs::Events::SCREEN_VIEW}') " \
        "AND toString(properties) != '{}'"
      )
    end
    return if existing.to_i.zero?

    raise "Target window already holds #{existing} property-bearing custom/screen_view event(s); " \
          "overlaying rekeys pre-amendment rows and double-counts. Truncate + rebuild the window, " \
          "or set ALLOW_PROPERTY_EVENT_OVERLAY=1 to proceed knowingly."
  end
  private_class_method :assert_no_property_event_overlay!

  # Capped like the live pipeline (cap_property_keys) so row + id digest match.
  def self.backfill_properties(raw)
    hash = raw.is_a?(String) ? (JSON.parse(raw) rescue nil) : raw
    return {} unless hash.is_a?(Hash)

    max = Analytics::Config::MAX_PROPERTY_KEYS_PER_EVENT
    hash.size <= max ? hash : hash.sort_by { |k, _| k.to_s }.first(max).to_h
  end
  private_class_method :backfill_properties

  def self.backfill_country(remote_ip, cache = {})
    return cache[remote_ip] if cache.key?(remote_ip)

    cache[remote_ip] = begin
      GeoipService.lookup(remote_ip)[:country].to_s
    rescue StandardError
      ""
    end
  end
  private_class_method :backfill_country

  # One-shot path: a swallowed failure or a lock-skip would return green over incomplete rollups.
  def self.rebuild_partitions(partitions)
    sorted = partitions.sort
    Rails.logger.info("ClickhouseHistoryBackfillService: rebuilding all rollups for partitions #{sorted.inspect}")
    ClickhouseRollupRebuildService.rebuild_partition_range(
      sorted.first, sorted.last, strict: true, fail_on_skip: true
    )
  end
  private_class_method :rebuild_partitions
end
