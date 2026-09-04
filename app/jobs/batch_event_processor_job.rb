class BatchEventProcessorJob # rubocop:disable Metrics/ClassLength
  include Sidekiq::Job
  sidekiq_options queue: :batch_events, retry: 3

  BATCH_SIZE = 500
  # 55s loop inside a 60s Sidekiq cron cycle: leaves ~5s for job overhead and
  # re-enqueue. The job pops batches in a loop rather than processing just once,
  # so a single Sidekiq slot can drain bursts without waiting for the next cron tick.
  LOOP_DURATION = 55.seconds.freeze
  SLEEP_INTERVAL = 2.seconds.freeze
  MAX_CONSECUTIVE_FAILURES = 3
  HEARTBEAT_INTERVAL = 10 # seconds — refresh heartbeat at most this often
  # 30s statement / 10s lock: event inserts and stat upserts touch hot rows
  # (link_daily_statistics, visitor_daily_statistics). Short lock_timeout prevents
  # one slow batch from blocking all other writers; statement_timeout caps runaway
  # queries while leaving room for large INSERT...ON CONFLICT batches.
  BATCH_STATEMENT_TIMEOUT = "30s".freeze
  BATCH_LOCK_TIMEOUT = "10s".freeze
  BATCH_WALL_CLOCK_LIMIT = 60 # seconds — break loop if a single batch exceeds this
  REDIS_KEY = "events:pending".freeze
  PROCESSING_KEY_PREFIX = "events:processing".freeze
  DEDUP_PREFIX = "events:dedup".freeze
  HEARTBEAT_PREFIX = "events:heartbeat".freeze
  HEARTBEAT_TTL = 120 # seconds — must be > LOOP_DURATION + worst-case timeout + cleanup
  CH_BATCH_DONE_PREFIX = "ch:done".freeze
  CH_BATCH_DONE_TTL = 3600 # 1 hour — well beyond heartbeat/recovery window
  MERGED_DEVICE_PREFIX = "events:device_merge".freeze
  # Visitorless payloads with no merge trace; replay is manual (rake events:drain_integrity_dlq).
  INTEGRITY_DLQ_KEY = "events:integrity_dlq".freeze
  INTEGRITY_DLQ_MAX = 10_000

  # Shared by the writer (MergeVisitorEventsJob) and reader (remap below)
  def self.merged_device_key(project_id, device_id)
    "#{MERGED_DEVICE_PREFIX}:#{project_id}:#{device_id}"
  end

  # Atomic replay (fix the root cause first): each LMOVE transfers one payload
  # back to pending with no loss window. Returns the number moved.
  def self.drain_integrity_dlq!
    moved = 0
    REDIS.with do |conn|
      moved += 1 while conn.rpoplpush(INTEGRITY_DLQ_KEY, REDIS_KEY)
    end
    moved
  end

  # Atomically pops up to ARGV[1] items from KEYS[1] (pending)
  # and pushes them onto KEYS[2] (processing). Returns the moved items.
  # Uses rpop+lpush instead of deprecated rpoplpush — safe because
  # Lua scripts execute atomically on the Redis server.
  POP_SCRIPT = <<~LUA.freeze
    local source = KEYS[1]
    local dest = KEYS[2]
    local count = tonumber(ARGV[1])
    local items = {}
    for i = 1, count do
      local item = redis.call('rpop', source)
      if not item then break end
      redis.call('lpush', dest, item)
      table.insert(items, item)
    end
    return items
  LUA

  # Atomically moves all items from KEYS[1] (processing) back to
  # KEYS[2] (pending) and deletes the processing key.
  REPUSH_SCRIPT = <<~LUA.freeze
    local processing_key = KEYS[1]
    local pending_key = KEYS[2]
    local items = redis.call('lrange', processing_key, 0, -1)
    if #items > 0 then
      redis.call('rpush', pending_key, unpack(items))
    end
    redis.call('del', processing_key)
    return #items
  LUA

  def perform
    refresh_heartbeat
    recover_orphaned_events

    deadline = Time.current + LOOP_DURATION
    consecutive_failures = 0
    last_heartbeat = Time.current

    while Time.current < deadline
      now = Time.current
      if now - last_heartbeat >= HEARTBEAT_INTERVAL
        refresh_heartbeat
        last_heartbeat = now
      end

      raw_events = pop_events(BATCH_SIZE)

      if raw_events.empty?
        sleep SLEEP_INTERVAL
        next
      end

      batch_start = Time.current
      result = process_batch(raw_events)
      batch_elapsed = Time.current - batch_start

      case result
      when :success
        consecutive_failures = 0
        if batch_elapsed > BATCH_WALL_CLOCK_LIMIT
          Rails.logger.warn("BatchEventProcessorJob: batch took #{batch_elapsed.round(1)}s (limit: #{BATCH_WALL_CLOCK_LIMIT}s), stopping loop")
          break
        end
      when :merge_deferred
        # Merge mid-flight, tray repushed; sleep in-loop (break would respawn via enqueue_if_backlog).
        sleep SLEEP_INTERVAL
      else # :failure
        consecutive_failures += 1
        if consecutive_failures >= MAX_CONSECUTIVE_FAILURES
          Rails.logger.error("BatchEventProcessorJob: #{MAX_CONSECUTIVE_FAILURES} consecutive failures, stopping until next run")
          break
        end
        sleep SLEEP_INTERVAL * consecutive_failures
      end
    end

    enqueue_if_backlog
  rescue StandardError => e
    Rails.logger.error("BatchEventProcessorJob fatal error: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    raise
  ensure
    begin
      REDIS.with { |conn| conn.del(heartbeat_key) }
    rescue Redis::BaseError
      nil
    end
  end

  private

  def processing_key
    @processing_key ||= "#{PROCESSING_KEY_PREFIX}:#{jid}"
  end

  def heartbeat_key
    @heartbeat_key ||= "#{HEARTBEAT_PREFIX}:#{jid}"
  end

  def refresh_heartbeat
    REDIS.with { |conn| conn.set(heartbeat_key, "1", ex: HEARTBEAT_TTL) }
  rescue Redis::BaseError => e
    Rails.logger.warn("BatchEventProcessorJob: heartbeat refresh failed: #{e.class} - #{e.message}")
  end

  # On startup, find processing lists left behind by crashed workers
  # and move their events back to the pending list for reprocessing.
  # Only recovers keys whose heartbeat has expired (worker is dead).
  # NOTE: conn.eval here is Redis#eval (executes a Lua script on the Redis server),
  # NOT Ruby's Kernel#eval. This is safe — the Lua script is a constant defined above.
  def recover_orphaned_events
    REDIS.with do |conn|
      cursor = "0"
      loop do
        cursor, keys = conn.scan(cursor, match: "#{PROCESSING_KEY_PREFIX}:*", count: 100)
        keys.each do |key|
          next if key == processing_key

          # Check if the worker that owns this key is still alive
          worker_jid = key.delete_prefix("#{PROCESSING_KEY_PREFIX}:")
          next if conn.exists?("#{HEARTBEAT_PREFIX}:#{worker_jid}")

          count = conn.eval(REPUSH_SCRIPT, keys: [key, REDIS_KEY])
          Rails.logger.warn("BatchEventProcessorJob: recovered #{count} orphaned events from #{key}") if count > 0
        end
        break if cursor == "0"
      end
    end
  rescue Redis::BaseError => e
    Rails.logger.warn("BatchEventProcessorJob: orphan recovery failed: #{e.class} - #{e.message}")
  end

  # Atomically pop events from pending into our processing list.
  def pop_events(count)
    REDIS.with { |conn| conn.eval(POP_SCRIPT, keys: [REDIS_KEY, processing_key], argv: [count]) }
  rescue Redis::BaseError => e
    Rails.logger.error("BatchEventProcessorJob: pop_events failed: #{e.class} - #{e.message}")
    []
  end

  def process_batch(raw_events)
    # Per batch: the builder's geo/alias caches must not survive a batch that raised.
    @ch_row_builder = nil
    parsed = parse_events(raw_events)
    if parsed.empty?
      REDIS.with { |conn| conn.del(processing_key) }
      return :success
    end

    remap_merged_devices!(parsed)
    ch_enabled = Clickhouse.enabled?

    projects, devices, links, visitors_index = bulk_load_records(parsed)

    # Before dedup, so a deferred batch repushes without dedup cleanup.
    if resolve_missing_visitors!(parsed, projects, devices, visitors_index) == :merge_deferred
      repush_from_processing
      return :merge_deferred
    end

    dedup_skip_indices, dedup_keys_we_set = pipeline_view_dedup(parsed, devices)

    event_rows, updates_batch, visitor_ids_to_touch, deduped_view_pairs =
      build_event_records(parsed, projects, devices, links, visitors_index, dedup_skip_indices)

    # Handle INSTALL/REINSTALL referral tracking
    referral_rows, referral_updates, inviter_assignments, referrer_visitors = handle_referrals(
      parsed, projects, devices, links, visitors_index
    )
    event_rows.concat(referral_rows)
    updates_batch.concat(referral_updates)

    # Referral rows reference the referrer's device — load devices and visitors
    # into the shared dicts so CH dual-write can denormalize referrer context.
    if referral_rows.any? && ch_enabled
      missing_device_ids = referral_rows.map { |r| r[:device_id] }.uniq - devices.keys
      # rubocop:disable Rails/FindEach -- bounded to a handful of referrer device IDs
      Device.where(id: missing_device_ids).each { |d| devices[d.id] = d } if missing_device_ids.any?
      # rubocop:enable Rails/FindEach

      # Merge referrer visitors into visitors_index so build_clickhouse_row
      # can resolve visitor_id, sdk_identifier, etc. for USER_REFERRED rows.
      referrer_visitors.each_value do |visitor|
        visitors_index[[visitor.project_id, visitor.device_id]] ||= visitor
      end
    end

    # CH-primary: one fast CH attempt before the txn; failures spill inside it (replay-safe)
    ch_primary = ch_enabled && Clickhouse.primary?
    spill_rows = ch_primary ? primary_ch_delivery(event_rows, devices, visitors_index, links) : []

    persist_batch(event_rows, updates_batch, visitor_ids_to_touch, inviter_assignments, parsed, visitors_index,
                  spill_rows: spill_rows, skip_pg_events: ch_primary)

    # The PG transaction committed — ack now (drop the processing list) regardless of
    # CH mode. CH durability is handled by the canonical DLQ: deliver_canonical parks a
    # failed write for idempotent replay (RMT dedups on event_id). We must NOT repush this
    # batch on a CH failure — replaying re-runs persist_batch, which double-inserts PG
    # `events` (no event_id unique key) and double-counts the additive stat upserts. In
    # primary mode spill rows ride the same transaction, so the batch is durable either way.
    REDIS.with { |conn| conn.del(processing_key) }

    touch_deduped_views(deduped_view_pairs)
    stamp_device_last_seen(event_rows)

    Rails.logger.info("BatchEventProcessorJob processed #{event_rows.size} events")

    if ch_primary
      finish_primary_write(visitors_index, devices)
    elsif ch_enabled
      dual_write_clickhouse(event_rows, devices, visitors_index, links)
    end
    :success
  rescue ActiveRecord::QueryCanceled => e
    Rails.logger.error("BatchEventProcessorJob: DB timeout: #{e.message}")
    cleanup_dedup_keys(dedup_keys_we_set) if defined?(dedup_keys_we_set) && dedup_keys_we_set
    repush_from_processing
    :failure
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.error("BatchEventProcessorJob batch error: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    cleanup_dedup_keys(dedup_keys_we_set) if defined?(dedup_keys_we_set) && dedup_keys_we_set
    repush_from_processing
    :failure
  rescue StandardError => e
    Rails.logger.error("BatchEventProcessorJob batch error: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    cleanup_dedup_keys(dedup_keys_we_set) if defined?(dedup_keys_we_set) && dedup_keys_we_set
    repush_from_processing
    :failure
  end

  def bulk_load_records(parsed)
    project_ids = parsed.map { |e| e[:project_id] }.uniq
    device_ids = parsed.map { |e| e[:device_id] }.uniq
    link_ids = parsed.map { |e| e[:link_id] }.compact.uniq

    projects = Project.where(id: project_ids).index_by(&:id)
    devices = Device.where(id: device_ids).index_by(&:id)
    links = link_ids.any? ? Link.where(id: link_ids).index_by(&:id) : {}
    visitors_index = load_visitors(parsed)

    [projects, devices, links, visitors_index]
  end

  def build_event_records(parsed, projects, devices, links, visitors_index, dedup_skip_indices)
    event_rows = []
    updates_batch = []
    visitor_ids_to_touch = Set.new
    deduped_view_pairs = Set.new

    parsed.each_with_index do |payload, idx|
      project = projects[payload[:project_id]]
      device = devices[payload[:device_id]]
      next unless project && device

      link = payload[:link_id] ? links[payload[:link_id]] : nil

      if dedup_skip_indices.include?(idx)
        deduped_view_pairs << [project.id, device.id]
        next
      end

      event_rows << build_event_row(payload, project, device, link)

      stats_update = build_stats_update(payload, project, device, link, visitors_index, visitor_ids_to_touch)
      updates_batch << stats_update if stats_update
    end

    [event_rows, updates_batch, visitor_ids_to_touch, deduped_view_pairs]
  end

  def build_event_row(payload, project, device, link)
    occurred_at = payload[:occurred_at]
    {
      event: payload[:type],
      project_id: project.id,
      device_id: device.id,
      link_id: link&.id,
      data: payload[:data],
      engagement_time: Event.clamp_engagement_time(payload[:engagement_time]),
      ip: device.ip,
      remote_ip: device.remote_ip,
      vendor_id: device.vendor,
      platform: device.platform,
      app_version: device.app_version,
      build: device.build,
      path: link&.path,
      processed: true,
      created_at: occurred_at,
      updated_at: occurred_at,
      event_name: payload[:event_name].to_s,
      session_id: payload[:session_id].to_s,
      tags: Array(payload[:tags]),
      ch_meta: ch_meta_from_payload(payload, link)
    }
  end

  # Frozen-at-ingest CH source carried alongside the PG row. NOT a PG column —
  # stripped before insert_all. Falls back to the link for pre-deploy in-flight
  # payloads that predate Phase 1 freezing. `key?` distinguishes "frozen as nil"
  # (organic) from "not frozen at all".
  def ch_meta_from_payload(payload, link)
    EventIngestionService.normalize_ch_meta(payload, link)
  end

  def build_stats_update(payload, project, device, link, visitors_index, visitor_ids_to_touch)
    metric = Grovs::Events::MAPPING[payload[:type]]
    return nil unless metric

    value = payload[:type] == Grovs::Events::TIME_SPENT ? Event.clamp_engagement_time(payload[:engagement_time]).to_i : 1
    platform = device.platform_for_metrics

    visitor = visitors_index[[project.id, device.id]]
    unless visitor
      Rails.logger.warn(
        "[BatchEventProcessor] Visitor not found for project_id=#{project.id} " \
        "device_id=#{device.id} event=#{payload[:type]} — stats skipped"
      )
      return nil
    end

    visitor_ids_to_touch << visitor.id
    event_date = payload[:occurred_at].to_date

    update = {
      visitor_updates: {
        stats: {
          project_id: project.id,
          visitor_id: visitor.id,
          invited_by_id: visitor.inviter_id,
          platform: platform,
          event_date: event_date,
          metrics: { metric => value }
        }
      },
      link_updates: nil
    }

    if link
      update[:link_updates] = {
        project_id: project.id,
        link_id: link.id,
        event_date: event_date,
        platform: platform,
        metrics: { metric => value }
      }
    end

    update
  end

  def persist_batch(event_rows, updates_batch, visitor_ids_to_touch, inviter_assignments, parsed, visitors_index,
                    spill_rows: [], skip_pg_events: false)
    # A worst-case statement chain outlives HEARTBEAT_TTL: recovery would repush a batch mid-commit.
    refresh_heartbeat
    ActiveRecord::Base.transaction do
      conn = ActiveRecord::Base.lease_connection
      conn.execute("SET LOCAL statement_timeout = '#{BATCH_STATEMENT_TIMEOUT}'")
      conn.execute("SET LOCAL lock_timeout = '#{BATCH_LOCK_TIMEOUT}'")

      insert_event_rows(event_rows) if event_rows.any? && !skip_pg_events
      ClickhouseSpillRepository.store(spill_rows) if spill_rows.any?

      begin
        EventStatDispatchService.bulk_process_updates(updates_batch) if updates_batch.any?
      rescue ActiveRecord::RangeError => e
        Rails.logger.error("BatchEventProcessorJob: RangeError on bulk_process_updates: #{e.message}")
        raise
      end

      Visitor.where(id: visitor_ids_to_touch.to_a).update_all(updated_at: Time.current) if visitor_ids_to_touch.any?

      inviter_assignments.each do |visitor_id, inviter_id|
        Visitor.where(id: visitor_id, inviter_id: nil).update_all(inviter_id: inviter_id)
      end

      bulk_upsert_visitor_last_visits(parsed, visitors_index)
    end
  end

  def insert_event_rows(event_rows)
    Event.insert_all(event_rows.map { |r| r.except(:ch_meta) })
  rescue ActiveRecord::InvalidForeignKey => e
    Rails.logger.warn("BatchEventProcessorJob: FK violation in insert_all, filtering bad rows: #{e.message}")
    valid_project_ids = Project.where(id: event_rows.pluck(:project_id).uniq).pluck(:id).to_set
    valid_device_ids = Device.where(id: event_rows.pluck(:device_id).uniq).pluck(:id).to_set
    event_rows.select! { |row| valid_project_ids.include?(row[:project_id]) && valid_device_ids.include?(row[:device_id]) }
    Event.insert_all(event_rows.map { |r| r.except(:ch_meta) }) if event_rows.any?
  rescue ActiveRecord::RangeError => e
    Rails.logger.error("BatchEventProcessorJob: RangeError on Event.insert_all: #{e.message}")
    event_rows.each_with_index do |row, i|
      row.each do |col, val|
        next unless val.is_a?(Numeric)
        Rails.logger.error("  row[#{i}] #{col}=#{val} (#{val.class})")
      end
    end
    raise
  end

  # For INSTALL/REINSTALL events with a referral link, set the inviter
  # and create USER_REFERRED events for the referrers.
  def handle_referrals(parsed, projects, devices, links, visitors_index)
    event_rows = []
    updates = []
    inviter_assignments = {}

    referral_events = parsed.select do |payload|
      [Grovs::Events::INSTALL, Grovs::Events::REINSTALL].include?(payload[:type]) && payload[:link_id]
    end
    return [event_rows, updates, inviter_assignments, {}] if referral_events.empty?

    # Load referrer visitors (the link creators) with their devices
    referrer_visitor_ids = referral_events.filter_map { |e| links[e[:link_id]]&.visitor_id }.uniq
    return [event_rows, updates, inviter_assignments, {}] if referrer_visitor_ids.empty?

    referrer_visitors = Visitor.where(id: referrer_visitor_ids).includes(:device).index_by(&:id)

    referral_events.each do |payload|
      project = projects[payload[:project_id]]
      device = devices[payload[:device_id]]
      link = links[payload[:link_id]]
      next unless project && device && link&.visitor_id

      installer_visitor = visitors_index[[project.id, device.id]]
      referrer = referrer_visitors[link.visitor_id]
      next unless installer_visitor && referrer && referrer.device

      # Set inviter if not already set
      unless installer_visitor.inviter_id
        inviter_assignments[installer_visitor.id] = referrer.id
      end

      occurred_at = payload[:occurred_at]

      # Create USER_REFERRED event credited to the referrer
      event_rows << {
        event: Grovs::Events::USER_REFERRED,
        project_id: project.id,
        device_id: referrer.device_id,
        link_id: nil,
        data: nil,
        engagement_time: nil,
        ip: referrer.device.ip,
        remote_ip: referrer.device.remote_ip,
        vendor_id: referrer.device.vendor,
        platform: referrer.device.platform,
        app_version: referrer.device.app_version,
        build: referrer.device.build,
        path: nil,
        processed: true,
        created_at: occurred_at,
        updated_at: occurred_at,
        event_name: "",
        session_id: "",
        tags: [],
        ch_meta: EventIngestionService.referral_ch_meta(ch_meta_from_payload(payload, link))
      }

      # Stats for USER_REFERRED
      metric = Grovs::Events::MAPPING[Grovs::Events::USER_REFERRED]
      if metric
        updates << {
          visitor_updates: {
            stats: {
              project_id: project.id,
              visitor_id: referrer.id,
              invited_by_id: referrer.inviter_id,
              platform: referrer.device.platform_for_metrics,
              event_date: occurred_at.to_date,
              metrics: { metric => 1 }
            }
          },
          link_updates: nil
        }
      end
    end

    [event_rows, updates, inviter_assignments, referrer_visitors]
  end

  # Load visitors for the exact (project_id, device_id) pairs in this batch.
  # Uses PostgreSQL row-value IN to avoid the cross-product problem of
  # two separate IN clauses loading all combinations.
  def load_visitors(parsed)
    pairs = parsed.map { |e| [e[:project_id], e[:device_id]] }.uniq
    return {} if pairs.empty?

    conn = ActiveRecord::Base.lease_connection
    tuples_sql = pairs.map { |pid, did| "(#{conn.quote(pid)}, #{conn.quote(did)})" }.join(", ")
    Visitor.where("(project_id, device_id) IN (#{tuples_sql})")
           .index_by { |v| [v.project_id, v.device_id] }
  end

  # Touch deduped VIEWs' created_at so the dedup window rolls forward.
  # Scoped to (project_id, device_id) pairs — dedup is project-scoped.
  def touch_deduped_views(project_device_pairs)
    return if project_device_pairs.empty?
    conn = ActiveRecord::Base.lease_connection
    tuples_sql = project_device_pairs.map { |pid, did| "(#{conn.quote(pid)}, #{conn.quote(did)})" }.join(", ")
    # 10s window (2x the 5s dedup TTL): accounts for clock skew between
    # Redis and Postgres plus batch processing latency. We only need to
    # find the "just-created" VIEW event to roll its timestamp forward.
    Event.where(event: Grovs::Events::VIEW)
         .where("(project_id, device_id) IN (#{tuples_sql})")
         .where("created_at >= ?", 10.seconds.ago)
         .update_all(created_at: Time.current)
  rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
    Rails.logger.warn("BatchEventProcessorJob: failed to touch deduped views: #{e.class} - #{e.message}")
  end

  # Newest event per device this batch — the SDK auth endpoint reads this instead of ClickHouse.
  def stamp_device_last_seen(event_rows)
    stamps = {}
    event_rows.each do |row|
      device_id = row[:device_id]
      next unless device_id
      # USER_REFERRED carries the REFERRER's device with the installer's time — credit, not activity.
      next if row[:event] == Grovs::Events::USER_REFERRED

      pair = [row[:project_id], device_id]
      occurred_at = row[:created_at]
      stamps[pair] = occurred_at if stamps[pair].nil? || occurred_at > stamps[pair]
    end
    DeviceLastSeen.stamp_batch!(stamps)
  rescue StandardError => e
    # Runs between the batch ack and the CH write — a raise here must not skip that write.
    Grovs::Metrics.increment("device_last_seen.stamp_failed", tags: { source: "batch" })
    Rails.logger.warn("BatchEventProcessorJob: last_seen stamp failed: #{e.class} - #{e.message}")
  end

  # Pipeline VIEW dedup: one SET NX per unique device, one Redis round-trip.
  #
  # Returns [skip_indices, keys_we_set]:
  #   skip_indices - Set of indices into `parsed` that should be skipped
  #   keys_we_set  - Array of Redis keys that WE set (for cleanup on batch failure)
  #
  # For each unique device with VIEW events in this batch:
  #   - Pipeline one SET NX per device (not per event)
  #   - If SET NX succeeds (new): allow the FIRST VIEW, skip the rest (intra-batch dedup)
  #   - If SET NX fails (exists): skip ALL VIEWs for that device (cross-batch dedup)
  #
  # Fails open: if Redis is down, returns empty sets (all VIEWs allowed).
  def pipeline_view_dedup(parsed, devices)
    # Group VIEW indices by (project_id, device_id): dedup is project-scoped so a VIEW
    # on one project can't drop a VIEW from the same device on another project.
    group_view_indices = Hash.new { |h, k| h[k] = [] }
    parsed.each_with_index do |payload, idx|
      next unless payload[:type] == Grovs::Events::VIEW
      device = devices[payload[:device_id]]
      next unless device
      group_view_indices[[payload[:project_id], device.id]] << idx
    end
    return [Set.new, []] if group_view_indices.empty?

    groups = group_view_indices.keys
    results = REDIS.with do |conn|
      conn.pipelined do |pipeline|
        groups.each do |project_id, device_id|
          # 5s TTL: VIEWs within this window are duplicates (matches the SDK re-send floor).
          pipeline.set("#{DEDUP_PREFIX}:#{project_id}:#{device_id}:view", "1", ex: 5, nx: true)
        end
      end
    end

    skip_indices = Set.new
    keys_we_set = []

    groups.each_with_index do |(project_id, device_id), i|
      indices = group_view_indices[[project_id, device_id]]

      if results[i]
        # No recent VIEW — keep the first, skip the rest (intra-batch dedup).
        keys_we_set << "#{DEDUP_PREFIX}:#{project_id}:#{device_id}:view"
        indices[1..].each { |idx| skip_indices << idx } if indices.size > 1
      else
        # Recent VIEW from a prior batch — skip all (cross-batch dedup).
        indices.each { |idx| skip_indices << idx }
      end
    end

    [skip_indices, keys_we_set]
  rescue Redis::BaseError => e
    Rails.logger.warn("BatchEventProcessorJob: VIEW dedup pipeline failed, allowing all VIEWs: #{e.class} - #{e.message}")
    [Set.new, []]
  end

  # Delete dedup keys that THIS batch set. Called on batch failure so
  # retried VIEWs aren't wrongly skipped. Only deletes keys where our
  # SET NX succeeded — keys from previous batches are left intact.
  def cleanup_dedup_keys(keys)
    return if keys.nil? || keys.empty?
    REDIS.with do |conn|
      conn.pipelined do |pipeline|
        keys.each { |key| pipeline.del(key) }
      end
    end
  rescue Redis::BaseError => e
    Rails.logger.warn("BatchEventProcessorJob: dedup key cleanup failed: #{e.class} - #{e.message}")
  end

  # Follow-up only above one pop's worth: cron covers remainders; any-nonzero re-enqueue bred redundant jobs.
  def enqueue_if_backlog
    pending = begin
      REDIS.with { |conn| conn.llen(REDIS_KEY) }
    rescue Redis::BaseError
      0
    end
    if pending > BATCH_SIZE
      BatchEventProcessorJob.perform_async
      Rails.logger.info("BatchEventProcessorJob: #{pending} events still pending, enqueued follow-up job")
    end
  rescue Redis::BaseError => e
    Rails.logger.warn("BatchEventProcessorJob: failed to enqueue follow-up: #{e.class} - #{e.message}")
  end

  # Rewrite device_id for merged devices via breadcrumb keys, following chains
  # (A→B→C) to the final device — stopping at B would resurrect a deleted visitor.
  MERGE_REMAP_MAX_HOPS = 5 # cycle guard

  def remap_merged_devices!(parsed)
    project_device_pairs = parsed.map { |p| [p[:project_id], p[:device_id]] }.uniq
    return if project_device_pairs.empty?

    remaps = {} # [project_id, original_device_id] => final device_id
    frontier = project_device_pairs.map { |pid, did| [pid, did, did] } # [pid, original, current]
    MERGE_REMAP_MAX_HOPS.times do
      mapped_ids = REDIS.mget(*frontier.map { |pid, _orig, cur| self.class.merged_device_key(pid, cur) })

      advanced = []
      frontier.each_with_index do |(pid, orig, cur), idx|
        to_id = mapped_ids[idx]
        next if to_id.blank? || to_id.to_i == cur

        remaps[[pid, orig]] = to_id.to_i
        advanced << [pid, orig, to_id.to_i]
      end
      break if advanced.empty?

      frontier = advanced
    end
    return if remaps.empty?

    parsed.each do |payload|
      to_device_id = remaps[[payload[:project_id], payload[:device_id]]]
      payload[:device_id] = to_device_id if to_device_id
    end
  rescue Redis::BaseError => e
    Rails.logger.warn("BatchEventProcessorJob: device merge remap failed: #{e.class} - #{e.message}")
  end

  # Missing visitor after the remap pass ⇒ a merge deleted it; the breadcrumb is
  # written before the delete commits, so it (or the merge lock) is visible by now.
  MISSING_VISITOR_RESOLVE_PASSES = 3

  def resolve_missing_visitors!(parsed, projects, devices, visitors_index)
    MISSING_VISITOR_RESOLVE_PASSES.times do
      missing = missing_visitor_payloads(parsed, projects, devices, visitors_index)
      return :resolved if missing.empty?

      remap_merged_devices!(missing)
      reload_remapped_records!(missing, devices, visitors_index)

      missing = missing_visitor_payloads(missing, projects, devices, visitors_index)
      return :resolved if missing.empty?

      breadcrumbs, locks = missing_merge_state(missing)
      next if breadcrumbs.any? # a merge just committed — re-run the remap pass

      return :merge_deferred if locks.any?

      park_integrity_payloads!(parsed, missing)
      return :resolved
    end
    :merge_deferred # breadcrumbs kept appearing under churn; defer rather than spin
  rescue Redis::BaseError => e
    # Defer, never fall through — that re-opens the visitorless corruption path.
    Rails.logger.error("BatchEventProcessorJob: missing-visitor resolve failed, deferring batch: #{e.class} - #{e.message}")
    :merge_deferred
  end

  def missing_visitor_payloads(payloads, projects, devices, visitors_index)
    payloads.select do |p|
      projects[p[:project_id]] && devices[p[:device_id]] &&
        !visitors_index[[p[:project_id], p[:device_id]]]
    end
  end

  def reload_remapped_records!(payloads, devices, visitors_index)
    new_device_ids = payloads.map { |p| p[:device_id] }.uniq - devices.keys
    devices.merge!(Device.where(id: new_device_ids).index_by(&:id)) if new_device_ids.any?
    visitors_index.merge!(load_visitors(payloads))
  end

  # One MGET: [breadcrumb, merge-lock] per payload.
  def missing_merge_state(missing)
    keys = missing.flat_map do |p|
      [self.class.merged_device_key(p[:project_id], p[:device_id]),
       "#{MergeVisitorEventsJob::LOCK_PREFIX}:#{p[:device_id]}:#{p[:project_id]}"]
    end
    values = REDIS.mget(*keys)
    pairs = values.each_slice(2).to_a
    [pairs.filter_map(&:first), pairs.filter_map(&:last)]
  end

  def park_integrity_payloads!(parsed, missing)
    REDIS.with do |conn|
      payloads = missing.map { |p| p.except(:occurred_at).to_json }
      # Idempotent: a tray repush after a later batch failure re-parks the same payloads.
      payloads.each { |json| conn.lrem(INTEGRITY_DLQ_KEY, 0, json) }
      new_len = conn.lpush(INTEGRITY_DLQ_KEY, payloads)
      conn.ltrim(INTEGRITY_DLQ_KEY, 0, INTEGRITY_DLQ_MAX - 1)
      # An eviction is a permanently lost event — surface it.
      evicted = new_len - INTEGRITY_DLQ_MAX
      if evicted.positive?
        Grovs::Metrics.increment("events.integrity_dlq.evicted", by: evicted)
        Rails.logger.error(
          "[BatchEventProcessor] CRITICAL — integrity DLQ full (#{INTEGRITY_DLQ_MAX}), " \
          "evicted #{evicted} oldest payload(s) permanently"
        )
      end
    end
    missing.each do |p|
      Rails.logger.error(
        "[BatchEventProcessor] INTEGRITY: visitor missing with no merge breadcrumb/lock — parked " \
        "project_id=#{p[:project_id]} device_id=#{p[:device_id]} type=#{p[:type]}"
      )
    end
    Grovs::Metrics.increment("events.integrity_parked", by: missing.size)
    parsed.reject! { |p| missing.include?(p) }
  end

  def repush_from_processing
    count = REDIS.with { |conn| conn.eval(REPUSH_SCRIPT, keys: [processing_key, REDIS_KEY]) }
    Rails.logger.warn("BatchEventProcessorJob: re-pushed #{count} events to pending after error") if count > 0
  rescue Redis::BaseError => e
    Rails.logger.error("BatchEventProcessorJob: CRITICAL - failed to re-push events: #{e.class} - #{e.message}")
  end

  def bulk_upsert_visitor_last_visits(parsed, visitors_index)
    # Collect the last link_id per (project_id, visitor_id) from events with a link
    last_links = {}
    parsed.each do |payload|
      next unless payload[:link_id]
      visitor = visitors_index[[payload[:project_id], payload[:device_id]]]
      next unless visitor
      # Later events in the batch overwrite earlier ones (last interaction wins)
      last_links[[payload[:project_id], visitor.id]] = payload[:link_id]
    end
    return if last_links.empty?

    now = Time.current
    # Sorted by conflict key so concurrent workers lock rows in the same order (no deadlocks)
    rows = last_links.sort_by { |key, _| key }.map do |(project_id, visitor_id), link_id|
      { project_id: project_id, visitor_id: visitor_id, link_id: link_id, created_at: now, updated_at: now }
    end

    # Savepoints (requires_new): an FK failure rolls back only that write, not the
    # surrounding persist_batch transaction.
    begin
      VisitorLastVisit.transaction(requires_new: true) do
        # on_duplicate, not update_only: must refresh updated_at too (merge picks by recency).
        VisitorLastVisit.upsert_all(
          rows,
          unique_by: %i[project_id visitor_id],
          on_duplicate: Arel.sql("link_id = excluded.link_id, updated_at = excluded.updated_at")
        )
      end
    rescue ActiveRecord::InvalidForeignKey => e
      # Deleted visitor — retry per-row so one stale row doesn't drop the rest.
      Rails.logger.warn("BatchEventProcessorJob: bulk visitor_last_visit FK violation, retrying per-row: #{e.message}")
      rows.each_with_index do |row, i|
        refresh_heartbeat if (i % 100).zero?
        VisitorLastVisit.transaction(requires_new: true) do
          VisitorLastVisit.upsert(row, unique_by: :index_vlv_on_project_and_visitor,
            on_duplicate: Arel.sql("link_id = excluded.link_id, updated_at = excluded.updated_at"))
        end
      rescue ActiveRecord::InvalidForeignKey => inner
        Rails.logger.warn("BatchEventProcessorJob: visitor_last_visit skip visitor_id=#{row[:visitor_id]}: #{inner.message}")
      end
    end
  end

  def safe_parse_time(time_string)
    return Time.current unless time_string.present?
    Time.parse(time_string)
  rescue ArgumentError, TypeError
    Rails.logger.warn("BatchEventProcessorJob: invalid timestamp '#{time_string}', using current time")
    Time.current
  end

  def parse_events(raw_events)
    raw_events.filter_map do |raw|
      payload = JSON.parse(raw, symbolize_names: true)

      unless payload[:type] && payload[:project_id] && payload[:device_id]
        Rails.logger.warn("BatchEventProcessorJob: skipping malformed event: #{raw}")
        next
      end

      unless Grovs::Events::ALL.include?(payload[:type])
        Rails.logger.warn("BatchEventProcessorJob: skipping invalid event type '#{payload[:type]}': #{raw}")
        next
      end

      # Pre-parse timestamp once so downstream code doesn't re-parse
      payload[:occurred_at] = safe_parse_time(payload[:created_at])

      payload
    rescue JSON::ParserError => e
      Rails.logger.warn("BatchEventProcessorJob: skipping invalid JSON: #{e.message}")
      nil
    end
  end

  # ── ClickHouse dual-write helpers ──────────────────────────────────────

  def ch_row_builder
    @ch_row_builder ||= ClickhouseEventRowBuilder.new
  end

  def primary_ch_delivery(event_rows, devices, visitors_index, links)
    ch_rows = ch_row_builder.build_rows(event_rows, devices, visitors_index, links)
    prepared = ClickhouseWriteService.prepare_canonical_rows(ch_rows)
    refresh_heartbeat
    if ClickhouseWriteService.insert_prepared_events(prepared)
      mark_rollup_partitions_dirty(prepared)
      []
    else
      prepared
    end
  end

  # Profiles are deliberately not spilled — self-heal on next event or via backfill.
  def finish_primary_write(visitors_index, devices)
    upsert_user_profiles(visitors_index, devices)
  rescue StandardError => e
    Rails.logger.error("BatchEventProcessorJob: primary user_profiles upsert failed: #{e.class} - #{e.message}")
  ensure
    @ch_row_builder = nil
  end

  def dual_write_clickhouse(event_rows, devices, visitors_index, links)
    # A device deleted before crash recovery shifts the fingerprint; worst case is a duplicate CH insert.
    ch_rows = ch_row_builder.build_rows(event_rows, devices, visitors_index, links)

    # Single, durable, deduped delivery into the one CH events table. event_id is a
    # DETERMINISTIC content hash, so ReplacingMergeTree collapses byte-identical
    # events — crash replays AND independent same-content re-ingests (a true retry is
    # data we WANT deduped; truth-first). engagement_time in the hash keeps same-ms
    # events with different durations distinct. Bounded-retry → DLQ, and refreshes the
    # heartbeat between attempts so a slow CH write isn't treated as an orphaned batch.
    # PG stays source of truth — does not move the PG ack.
    delivered = deliver_canonical_with_heartbeat(ch_rows)

    upsert_user_profiles(visitors_index, devices)
    delivered
  rescue StandardError => e
    Rails.logger.error("BatchEventProcessorJob: ClickHouse dual-write failed: #{e.class} - #{e.message}")
    false
  ensure
    @ch_row_builder = nil
  end

  def upsert_user_profiles(visitors_index, devices)
    now = Time.current
    seen = Set.new
    rows = []

    visitors_index.each_value do |visitor|
      next if seen.include?(visitor.id)
      seen << visitor.id

      device = devices[visitor.device_id]
      next unless device

      rows << {
        project_id: visitor.project_id,
        visitor_id: visitor.id,
        sdk_identifier: visitor.sdk_identifier.to_s,
        uuid: visitor.uuid.to_s,
        properties: ch_row_builder.cap_property_keys(ch_row_builder.ensure_hash(visitor.sdk_attributes)),
        first_seen: visitor.created_at,
        last_seen: now,
        country: ch_row_builder.geo_lookup(device.remote_ip)[:country],
        platform: device.platform_for_metrics,
        inviter_id: visitor.inviter_id || 0
      }
    end

    ClickhouseWriteService.upsert_user_profiles(rows)
  end

  # Refresh the heartbeat before each canonical delivery attempt so a slow CH
  # write (retries + HTTP timeout) doesn't exceed the orphan-recovery window and
  # cause another worker to repush a batch that's still being delivered.
  def deliver_canonical_with_heartbeat(ch_rows)
    delivered = ClickhouseWriteService.deliver_canonical(ch_rows, before_attempt: -> { refresh_heartbeat })
    mark_rollup_partitions_dirty(ch_rows) if delivered
    delivered
  end

  # Record the YYYYMM partitions touched by this batch so RebuildClickhouseRollupsJob
  # rebuilds only partitions that received new canonical events. Isolated: a dirty-mark
  # failure must never break delivery (the watermark window is the safety net).
  def mark_rollup_partitions_dirty(ch_rows)
    ch_rows.filter_map { |r| r[:created_at] }.each do |created_at|
      ClickhouseRollupRebuildService.mark_dirty(created_at.to_date)
    end
  rescue StandardError => e
    Rails.logger.warn("BatchEventProcessorJob: mark_rollup_partitions_dirty failed: #{e.class} - #{e.message}")
  end


end
