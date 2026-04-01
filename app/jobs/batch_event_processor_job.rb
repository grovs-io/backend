class BatchEventProcessorJob
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
      success = process_batch(raw_events)
      batch_elapsed = Time.current - batch_start

      if success
        consecutive_failures = 0
        if batch_elapsed > BATCH_WALL_CLOCK_LIMIT
          Rails.logger.warn("BatchEventProcessorJob: batch took #{batch_elapsed.round(1)}s (limit: #{BATCH_WALL_CLOCK_LIMIT}s), stopping loop")
          break
        end
      else
        consecutive_failures += 1
        if consecutive_failures >= MAX_CONSECUTIVE_FAILURES
          Rails.logger.error("BatchEventProcessorJob: #{MAX_CONSECUTIVE_FAILURES} consecutive failures, stopping until next run")
          break
        end
        sleep SLEEP_INTERVAL * consecutive_failures
      end
    end

    # If there are still pending events, enqueue another job immediately
    # so the next available worker picks it up without waiting for cron.
    enqueue_if_backlog
  rescue StandardError => e
    Rails.logger.error("BatchEventProcessorJob fatal error: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    raise
  ensure
    begin
      REDIS.del(heartbeat_key)
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
    REDIS.set(heartbeat_key, "1", ex: HEARTBEAT_TTL)
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
    REDIS.eval(POP_SCRIPT, keys: [REDIS_KEY, processing_key], argv: [count])
  rescue Redis::BaseError => e
    Rails.logger.error("BatchEventProcessorJob: pop_events failed: #{e.class} - #{e.message}")
    []
  end

  def process_batch(raw_events)
    parsed = parse_events(raw_events)
    if parsed.empty?
      REDIS.del(processing_key)
      return true
    end

    projects, devices, links, visitors_index = bulk_load_records(parsed)

    dedup_skip_indices, dedup_keys_we_set = pipeline_view_dedup(parsed, devices)

    event_rows, updates_batch, visitor_ids_to_touch, dedup_device_ids =
      build_event_records(parsed, projects, devices, links, visitors_index, dedup_skip_indices)

    # Handle INSTALL/REINSTALL referral tracking
    referral_rows, referral_updates, inviter_assignments = handle_referrals(
      parsed, projects, devices, links, visitors_index
    )
    event_rows.concat(referral_rows)
    updates_batch.concat(referral_updates)

    persist_batch(event_rows, updates_batch, visitor_ids_to_touch, inviter_assignments, parsed, visitors_index)

    # Transaction succeeded — safe to discard the processing list
    REDIS.del(processing_key)

    touch_deduped_views(dedup_device_ids)

    Rails.logger.info("BatchEventProcessorJob processed #{event_rows.size} events")
    true
  rescue ActiveRecord::QueryCanceled => e
    Rails.logger.error("BatchEventProcessorJob: DB timeout: #{e.message}")
    cleanup_dedup_keys(dedup_keys_we_set) if defined?(dedup_keys_we_set) && dedup_keys_we_set
    repush_from_processing
    false
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.error("BatchEventProcessorJob batch error: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    cleanup_dedup_keys(dedup_keys_we_set) if defined?(dedup_keys_we_set) && dedup_keys_we_set
    repush_from_processing
    false
  rescue StandardError => e
    Rails.logger.error("BatchEventProcessorJob batch error: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    cleanup_dedup_keys(dedup_keys_we_set) if defined?(dedup_keys_we_set) && dedup_keys_we_set
    repush_from_processing
    false
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
    dedup_device_ids = Set.new

    parsed.each_with_index do |payload, idx|
      project = projects[payload[:project_id]]
      device = devices[payload[:device_id]]
      next unless project && device

      link = payload[:link_id] ? links[payload[:link_id]] : nil

      if dedup_skip_indices.include?(idx)
        dedup_device_ids << device.id
        next
      end

      event_rows << build_event_row(payload, project, device, link)

      stats_update = build_stats_update(payload, project, device, link, visitors_index, visitor_ids_to_touch)
      updates_batch << stats_update if stats_update
    end

    [event_rows, updates_batch, visitor_ids_to_touch, dedup_device_ids]
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
      updated_at: occurred_at
    }
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

  def persist_batch(event_rows, updates_batch, visitor_ids_to_touch, inviter_assignments, parsed, visitors_index)
    ActiveRecord::Base.transaction do
      conn = ActiveRecord::Base.lease_connection
      conn.execute("SET LOCAL statement_timeout = '#{BATCH_STATEMENT_TIMEOUT}'")
      conn.execute("SET LOCAL lock_timeout = '#{BATCH_LOCK_TIMEOUT}'")

      insert_event_rows(event_rows) if event_rows.any?

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
    Event.insert_all(event_rows)
  rescue ActiveRecord::InvalidForeignKey => e
    Rails.logger.warn("BatchEventProcessorJob: FK violation in insert_all, filtering bad rows: #{e.message}")
    valid_project_ids = Project.where(id: event_rows.pluck(:project_id).uniq).pluck(:id).to_set
    valid_device_ids = Device.where(id: event_rows.pluck(:device_id).uniq).pluck(:id).to_set
    event_rows.select! { |row| valid_project_ids.include?(row[:project_id]) && valid_device_ids.include?(row[:device_id]) }
    Event.insert_all(event_rows) if event_rows.any?
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
    return [event_rows, updates, inviter_assignments] if referral_events.empty?

    # Load referrer visitors (the link creators) with their devices
    referrer_visitor_ids = referral_events.filter_map { |e| links[e[:link_id]]&.visitor_id }.uniq
    return [event_rows, updates, inviter_assignments] if referrer_visitor_ids.empty?

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
        updated_at: occurred_at
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

    [event_rows, updates, inviter_assignments]
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

  # Matches old dedup behavior: when a VIEW is deduplicated, touch
  # the existing event's created_at so the dedup window rolls forward.
  def touch_deduped_views(device_ids)
    return if device_ids.empty?
    # 10s window (2x the 5s dedup TTL): accounts for clock skew between
    # Redis and Postgres plus batch processing latency. We only need to
    # find the "just-created" VIEW event to roll its timestamp forward.
    Event.where(event: Grovs::Events::VIEW, device_id: device_ids.to_a)
         .where("created_at >= ?", 10.seconds.ago)
         .update_all(created_at: Time.current)
  rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
    Rails.logger.warn("BatchEventProcessorJob: failed to touch deduped views: #{e.class} - #{e.message}")
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
    # Group VIEW event indices by device_id
    device_view_indices = Hash.new { |h, k| h[k] = [] }
    parsed.each_with_index do |payload, idx|
      next unless payload[:type] == Grovs::Events::VIEW
      device = devices[payload[:device_id]]
      next unless device
      device_view_indices[device.id] << idx
    end
    return [Set.new, []] if device_view_indices.empty?

    # Pipeline one SET NX per unique device
    unique_device_ids = device_view_indices.keys
    results = REDIS.with do |conn|
      conn.pipelined do |pipeline|
        unique_device_ids.each do |device_id|
          # 5s TTL: VIEW events within this window are considered duplicates.
          # Matches the SDK's minimum re-send interval, so legitimate re-opens
          # after 5s are counted while rapid-fire duplicates (retries, double-taps) are not.
          pipeline.set("#{DEDUP_PREFIX}:#{device_id}:view", "1", ex: 5, nx: true)
        end
      end
    end

    skip_indices = Set.new
    keys_we_set = []

    unique_device_ids.each_with_index do |device_id, i|
      indices = device_view_indices[device_id]

      if results[i]
        # SET NX succeeded — this device had no recent VIEW. Allow the
        # first VIEW in this batch, skip the rest (intra-batch dedup).
        keys_we_set << "#{DEDUP_PREFIX}:#{device_id}:view"
        indices[1..].each { |idx| skip_indices << idx } if indices.size > 1
      else
        # SET NX failed — device already has a recent VIEW from a previous
        # batch. Skip ALL VIEWs for this device (cross-batch dedup).
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

  # Atomically move all events from our processing list back to pending.
  # Uses a Lua script so there's no window where events exist in neither list.
  # If the pending list still has events after this job finishes its loop,
  # enqueue another job so a free worker picks it up immediately instead of
  # waiting for the next cron tick (up to 60 seconds away).
  def enqueue_if_backlog
    pending = begin
      REDIS.llen(REDIS_KEY)
    rescue Redis::BaseError
      0
    end
    if pending > 0
      BatchEventProcessorJob.perform_async
      Rails.logger.info("BatchEventProcessorJob: #{pending} events still pending, enqueued follow-up job")
    end
  rescue Redis::BaseError => e
    Rails.logger.warn("BatchEventProcessorJob: failed to enqueue follow-up: #{e.class} - #{e.message}")
  end

  def repush_from_processing
    count = REDIS.eval(REPUSH_SCRIPT, keys: [processing_key, REDIS_KEY])
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

    last_links.each do |(project_id, visitor_id), link_id|
      vlv = VisitorLastVisit.find_or_initialize_by(project_id: project_id, visitor_id: visitor_id)
      vlv.link_id = link_id
      vlv.save!
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

end
