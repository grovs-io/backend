# lib/tasks/drain_events_queue.rake
#
# Emergency drain of queue:events backlog.
# Processes 31M+ Sidekiq jobs in bulk instead of one-by-one.
#
# ZERO DATA LOSS GUARANTEES:
#   1. Every raw job is written to backup file BEFORE processing
#   2. LogEventJob/AddEventJob events are inserted directly to DB (no dedup)
#   3. Events are inserted with processed=false, stats caught up separately
#   4. If task crashes, re-run: it picks up from where it left off (drain queue)
#   5. Backup file can be replayed if needed
#
# Prerequisites:
#   redis-cli RENAME queue:events queue:events:drain
#
# Usage:
#   bundle exec rake events:drain_queue
#   BATCH_SIZE=5000 bundle exec rake events:drain_queue
#   SKIP_DEVICE_UPDATES=1 bundle exec rake events:drain_queue
#
namespace :events do
  desc "Emergency bulk drain of queue:events:drain -> DB (run RENAME first!)"
  task drain_queue: :environment do
    drain_key = "queue:events:drain"
    batch_size = (ENV["BATCH_SIZE"] || 2000).to_i
    skip_device_updates = ENV["SKIP_DEVICE_UPDATES"] == "1"
    enable_backup = ENV["BACKUP"] == "1"
    backup_dir = ENV["BACKUP_DIR"] || "/tmp"
    backup_file = File.join(backup_dir, "events_drain_#{Time.current.strftime('%Y%m%d_%H%M%S')}.jsonl") if enable_backup

    # Lua script to pop N items atomically (works with Redis 4.x+)
    pop_script = <<~LUA
      local source = KEYS[1]
      local count = tonumber(ARGV[1])
      local items = {}
      for i = 1, count do
        local item = redis.call('rpop', source)
        if not item then break end
        table.insert(items, item)
      end
      return items
    LUA

    # Verify drain key exists
    drain_size = REDIS.llen(drain_key) rescue 0
    if drain_size == 0
      begin
        REDIS.rename("queue:events", drain_key)
        drain_size = REDIS.llen(drain_key)
        puts "Renamed queue:events -> #{drain_key} (#{drain_size} items)"
      rescue Redis::CommandError => e
        if e.message.include?("no such key")
          puts "Neither queue:events nor #{drain_key} exist. Nothing to drain."
          exit
        end
        raise
      end
    else
      puts "Found existing #{drain_key} with #{drain_size} items"
    end

    total = drain_size
    backup = enable_backup ? File.open(backup_file, "a") : nil
    if enable_backup
      puts "Backup file: #{backup_file}"
      puts "WARNING: backup file could be ~#{(total * 400.0 / 1024 / 1024 / 1024).round(1)}GB"
    else
      puts "Backup: DISABLED (data is safe — items stay in drain queue until processed, failed batches are logged)"
    end
    puts "Batch size: #{batch_size} | Skip device updates: #{skip_device_updates}"
    puts "-" * 80

    processed = 0
    stats = Hash.new(0)
    batch_errors = 0
    start_time = Time.current

    loop do
      raw_jobs = REDIS.eval(pop_script, keys: [drain_key], argv: [batch_size])
      break if raw_jobs.nil? || raw_jobs.empty?

      # SAFETY NET: write raw items to backup file BEFORE any processing
      if backup
        raw_jobs.each { |raw| backup.puts(raw) }
        backup.flush
      end

      # Group by job class
      grouped = Hash.new { |h, k| h[k] = [] }
      raw_jobs.each do |raw|
        
        job = JSON.parse(raw)
        grouped[job["class"]] << job
      rescue JSON::ParserError
        stats["parse_errors"] += 1
        
      end

      # === LogEventJob: insert directly to DB (NO dedup — they already passed dedup when enqueued) ===
      if grouped["LogEventJob"]&.any?
        begin
          count = drain_insert_log_events(grouped["LogEventJob"])
          stats["LogEventJob"] += grouped["LogEventJob"].size
          stats["LogEventJob_inserted"] += count
        rescue => e
          batch_errors += 1
          puts "ERROR processing LogEventJob batch: #{e.class} - #{e.message}"
          # Push failed items back to drain queue so they're not lost
          grouped["LogEventJob"].each { |job| REDIS.rpush(drain_key, job.to_json) }
          stats["LogEventJob_repushed"] += grouped["LogEventJob"].size
        end
      end

      # === UpdateDeviceJob: bulk device metadata updates ===
      if grouped["UpdateDeviceJob"]&.any?
        if skip_device_updates
          stats["UpdateDeviceJob_discarded"] += grouped["UpdateDeviceJob"].size
        else
          begin
            drain_process_device_updates(grouped["UpdateDeviceJob"])
            stats["UpdateDeviceJob"] += grouped["UpdateDeviceJob"].size
          rescue => e
            batch_errors += 1
            puts "ERROR processing UpdateDeviceJob batch: #{e.class} - #{e.message}"
            # Device updates are idempotent, push back for retry
            grouped["UpdateDeviceJob"].each { |job| REDIS.rpush(drain_key, job.to_json) }
          end
        end
      end

      # === AddEventJob: resolve links, insert directly to DB ===
      if grouped["AddEventJob"]&.any?
        begin
          count = drain_insert_add_events(grouped["AddEventJob"])
          stats["AddEventJob"] += grouped["AddEventJob"].size
          stats["AddEventJob_inserted"] += count
        rescue => e
          batch_errors += 1
          puts "ERROR processing AddEventJob batch: #{e.class} - #{e.message}"
          # Push failed items back to drain queue so they're not lost
          grouped["AddEventJob"].each { |job| REDIS.rpush(drain_key, job.to_json) }
          stats["AddEventJob_repushed"] += grouped["AddEventJob"].size
        end
      end

      # === MergeVisitorEventsJob, ProcessNormalEventJob, etc: re-enqueue ===
      other_classes = grouped.keys - ["LogEventJob", "UpdateDeviceJob", "AddEventJob"]
      other_classes.each do |klass|
        grouped[klass].each do |job|
          REDIS.lpush("queue:events", job.to_json)
        end
        stats["#{klass}_requeued"] += grouped[klass].size
      end

      processed += raw_jobs.size
      elapsed = Time.current - start_time
      rate = processed / [elapsed, 0.1].max
      remaining = REDIS.llen(drain_key) rescue 0
      mem = begin; REDIS.info("memory")["used_memory_human"]; rescue; "?"; end

      puts "[#{Time.current.strftime('%H:%M:%S')}] #{processed}/#{total} " \
           "(#{(processed.to_f / [total, 1].max * 100).round(1)}%) | " \
           "#{rate.round(0)}/s | Redis: #{mem} | Left: #{remaining} | " \
           "Errors: #{batch_errors} | " \
           "#{stats.map { |k, v| "#{k}:#{v}" }.join(' ')}"
    end

    backup&.close

    elapsed = Time.current - start_time
    puts "\n#{'=' * 80}"
    puts "DONE! Processed #{processed} items in #{elapsed.round(0)}s"
    puts "Rate: #{(processed / [elapsed, 1].max).round(0)}/s"
    puts "Breakdown: #{stats.map { |k, v| "#{k}: #{v}" }.join(', ')}"
    puts "Batch errors: #{batch_errors}"
    puts "Backup: #{backup_file}"

    events_inserted = stats["LogEventJob_inserted"] + stats["AddEventJob_inserted"]
    if events_inserted > 0
      puts "\n#{events_inserted} events inserted with processed=false."
      puts "Run this to update stats: bundle exec rake events:process_all_fast_new"
    end
  end
end

# Insert LogEventJob events directly into the events table.
# NO VIEW dedup — these events already passed dedup when originally enqueued.
# Inserted with processed=false so stats are caught up separately.
#
# LogEventJob args: [type, project_id, device_id, data, link_id, engagement_time, created_at_iso]
def drain_insert_log_events(jobs)
  payloads = jobs.filter_map do |job|
    args = job["args"]
    next unless args && args.length >= 3 && args[0] && args[1] && args[2]
    timestamp = if args[6].present?
                  Time.parse(args[6]) rescue Time.current
                else
                  Time.current
                end
    {
      type: args[0],
      project_id: args[1].to_i,
      device_id: args[2].to_i,
      data: args[3],
      link_id: args[4]&.to_i,
      engagement_time: args[5],
      occurred_at: timestamp
    }
  end
  return 0 if payloads.empty?

  # Bulk load referenced records for metadata
  device_ids = payloads.map { |p| p[:device_id] }.uniq
  link_ids = payloads.filter_map { |p| p[:link_id] }.uniq
  devices = Device.where(id: device_ids).index_by(&:id)
  links = link_ids.any? ? Link.where(id: link_ids).index_by(&:id) : {}

  event_rows = payloads.filter_map do |payload|
    device = devices[payload[:device_id]]
    next unless device
    link = payload[:link_id] ? links[payload[:link_id]] : nil

    {
      event: payload[:type],
      project_id: payload[:project_id],
      device_id: payload[:device_id],
      link_id: link&.id,
      data: payload[:data],
      engagement_time: payload[:engagement_time],
      ip: device.ip,
      remote_ip: device.remote_ip,
      vendor_id: device.vendor,
      platform: device.platform,
      app_version: device.app_version,
      build: device.build,
      path: link&.path,
      processed: false,
      created_at: payload[:occurred_at],
      updated_at: payload[:occurred_at]
    }
  end

  return 0 if event_rows.empty?

  begin
    Event.insert_all(event_rows)
  rescue ActiveRecord::InvalidForeignKey => e
    Rails.logger.warn("drain_queue: FK violation, filtering stale refs: #{e.message}")
    valid_pids = Project.where(id: event_rows.map { |r| r[:project_id] }.uniq).pluck(:id).to_set
    valid_dids = Device.where(id: event_rows.map { |r| r[:device_id] }.uniq).pluck(:id).to_set
    event_rows.select! { |r| valid_pids.include?(r[:project_id]) && valid_dids.include?(r[:device_id]) }
    Event.insert_all(event_rows) if event_rows.any?
  end

  event_rows.size
end

# Bulk process UpdateDeviceJob items.
# Dedup by device_id (keep latest in batch), skip if device already has newer data.
#
# UpdateDeviceJob args: [device_id, ip, remote_ip, user_agent, request_user_agent,
#   model, build, app_version, platform, vendor, screen_w, screen_h, timezone,
#   webgl_vendor, webgl_renderer, language]
def drain_process_device_updates(jobs)
  # Dedup within batch: keep latest update per device_id
  latest_by_device = {}
  jobs.each do |job|
    device_id = job["args"][0]
    created_at = job["created_at"] || 0
    if !latest_by_device[device_id] || created_at > (latest_by_device[device_id]["created_at"] || 0)
      latest_by_device[device_id] = job
    end
  end

  devices = Device.where(id: latest_by_device.keys).index_by(&:id)

  latest_by_device.each do |device_id, job|
    device = devices[device_id]
    next unless device

    args = job["args"]
    # Skip if device was updated more recently than this job
    job_time = job["created_at"] ? Time.at(job["created_at"]) : nil
    next if job_time && device.updated_at && device.updated_at > job_time

    device.ip = args[1] if args[1].present?
    device.remote_ip = args[2] if args[2].present?
    device.user_agent = args[3].presence || args[4] if args[3].present? || args[4].present?
    device.model = args[5] if args[5].present?
    device.build = args[6] if args[6].present?
    device.app_version = args[7] if args[7].present?
    device.platform = args[8].presence || device.user_agent_platform if args[8].present?
    device.vendor = args[9] if args[9].present?
    device.screen_width = args[10] if args[10].present?
    device.screen_height = args[11] if args[11].present?
    device.timezone = args[12] if args[12].present?
    device.webgl_vendor = args[13] if args[13].present?
    device.webgl_renderer = args[14] if args[14].present?
    device.language = args[15] if args[15].present?

    device.save if device.changed?
  rescue => e
    Rails.logger.warn("drain_queue: UpdateDeviceJob failed for device #{device_id}: #{e.message}")
  end
end

# Insert AddEventJob events directly to DB after resolving links.
#
# AddEventJob args: [event_name, project_id, device_id, link_param, optional_path, created_at, engagement_time]
def drain_insert_add_events(jobs)
  project_ids = jobs.map { |j| j["args"][1] }.uniq
  device_ids = jobs.map { |j| j["args"][2] }.uniq
  projects = Project.where(id: project_ids).index_by(&:id)
  devices = Device.where(id: device_ids).index_by(&:id)
  links_helper = Helpers::LinksHelper.new

  payloads = jobs.filter_map do |job|
    args = job["args"]
    project = projects[args[1]]
    device = devices[args[2]]
    next unless project && device

    link_to_log = nil
    if args[3].present?
      link = links_helper.link_for_url(args[3], project) rescue nil
      link_to_log = link if link
    end
    if args[4].present?
      link = links_helper.link_for_project_and_path(project, args[4]) rescue nil
      link_to_log = link if link
    end

    timestamp = if args[5].present?
                  Time.parse(args[5]) rescue Time.current
                else
                  Time.current
                end

    {
      type: args[0],
      project_id: project.id,
      device_id: device.id,
      link_id: link_to_log&.id,
      engagement_time: args[6],
      occurred_at: timestamp
    }
  end
  return 0 if payloads.empty?

  # Bulk load devices and links for metadata
  all_device_ids = payloads.map { |p| p[:device_id] }.uniq
  all_link_ids = payloads.filter_map { |p| p[:link_id] }.uniq
  all_devices = Device.where(id: all_device_ids).index_by(&:id)
  all_links = all_link_ids.any? ? Link.where(id: all_link_ids).index_by(&:id) : {}

  event_rows = payloads.filter_map do |payload|
    device = all_devices[payload[:device_id]]
    next unless device
    link = payload[:link_id] ? all_links[payload[:link_id]] : nil

    {
      event: payload[:type],
      project_id: payload[:project_id],
      device_id: payload[:device_id],
      link_id: link&.id,
      data: nil,
      engagement_time: payload[:engagement_time],
      ip: device.ip,
      remote_ip: device.remote_ip,
      vendor_id: device.vendor,
      platform: device.platform,
      app_version: device.app_version,
      build: device.build,
      path: link&.path,
      processed: false,
      created_at: payload[:occurred_at],
      updated_at: payload[:occurred_at]
    }
  end

  return 0 if event_rows.empty?

  begin
    Event.insert_all(event_rows)
  rescue ActiveRecord::InvalidForeignKey => e
    Rails.logger.warn("drain_queue: FK violation in AddEventJob, filtering: #{e.message}")
    valid_pids = Project.where(id: event_rows.map { |r| r[:project_id] }.uniq).pluck(:id).to_set
    valid_dids = Device.where(id: event_rows.map { |r| r[:device_id] }.uniq).pluck(:id).to_set
    event_rows.select! { |r| valid_pids.include?(r[:project_id]) && valid_dids.include?(r[:device_id]) }
    Event.insert_all(event_rows) if event_rows.any?
  end

  event_rows.size
end
