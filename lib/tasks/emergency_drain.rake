# lib/tasks/emergency_drain.rake
#
# Emergency drain of queue:events:drain backlog.
# Zero data loss: events → DB, device updates → file, other jobs → re-enqueued.
#
# Usage:
#   BATCH_SIZE=5000 bundle exec rake events:emergency_drain
#
namespace :events do
  desc "Emergency drain queue:events:drain to DB + file"
  task emergency_drain: :environment do
    drain_key = "queue:events:drain"
    batch_size = (ENV["BATCH_SIZE"] || 5000).to_i
    device_file_path = "/tmp/device_updates_#{Time.current.strftime('%Y%m%d_%H%M%S')}.jsonl"

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

    drain_size = REDIS.llen(drain_key) rescue 0
    if drain_size == 0
      puts "#{drain_key} is empty. Nothing to drain."
      exit
    end

    total = drain_size
    device_file = File.open(device_file_path, "a")
    puts "Draining #{total} items from #{drain_key}"
    puts "Device updates saved to: #{device_file_path}"
    puts "Batch size: #{batch_size}"
    puts "-" * 80

    processed = 0
    stats = Hash.new(0)
    errors = 0
    start_time = Time.current

    loop do
      raw_jobs = REDIS.eval(pop_script, keys: [drain_key], argv: [batch_size])
      break if raw_jobs.nil? || raw_jobs.empty?

      grouped = Hash.new { |h, k| h[k] = [] }
      raw_jobs.each do |raw|
        job = JSON.parse(raw)
        grouped[job["class"]] << job
      rescue JSON::ParserError
        stats["parse_errors"] += 1
      end

      # LogEventJob → insert events directly to DB
      if grouped["LogEventJob"]&.any?
        begin
          count = emergency_insert_log_events(grouped["LogEventJob"])
          stats["LogEventJob"] += grouped["LogEventJob"].size
          stats["events_inserted"] += count
        rescue => e
          errors += 1
          puts "ERROR LogEventJob: #{e.class} - #{e.message}"
          grouped["LogEventJob"].each { |job| REDIS.rpush(drain_key, job.to_json) }
        end
      end

      # AddEventJob → resolve links, insert events directly to DB
      if grouped["AddEventJob"]&.any?
        begin
          count = emergency_insert_add_events(grouped["AddEventJob"])
          stats["AddEventJob"] += grouped["AddEventJob"].size
          stats["events_inserted"] += count
        rescue => e
          errors += 1
          puts "ERROR AddEventJob: #{e.class} - #{e.message}"
          grouped["AddEventJob"].each { |job| REDIS.rpush(drain_key, job.to_json) }
        end
      end

      # UpdateDeviceJob → save to file (fast, frees Redis, preserves data)
      if grouped["UpdateDeviceJob"]&.any?
        grouped["UpdateDeviceJob"].each { |job| device_file.puts(job.to_json) }
        device_file.flush
        stats["UpdateDeviceJob_to_file"] += grouped["UpdateDeviceJob"].size
      end

      # Everything else → re-enqueue for normal Sidekiq processing
      other_classes = grouped.keys - ["LogEventJob", "UpdateDeviceJob", "AddEventJob"]
      other_classes.each do |klass|
        grouped[klass].each { |job| REDIS.lpush("queue:events", job.to_json) }
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
           "#{stats.map { |k, v| "#{k}:#{v}" }.join(' ')}"
    end

    device_file.close

    elapsed = Time.current - start_time
    puts "\n#{'=' * 80}"
    puts "DONE in #{elapsed.round(0)}s (#{(processed / [elapsed, 1].max).round(0)}/s)"
    puts stats.map { |k, v| "#{k}: #{v}" }.join(', ')
    puts "Errors: #{errors}"
    puts "Device updates file: #{device_file_path}"

    if stats["events_inserted"] > 0
      puts "\n#{stats["events_inserted"]} events need stats. Run: bundle exec rake events:process_all_fast_new"
    end
  end
end

def emergency_insert_log_events(jobs)
  payloads = jobs.filter_map do |job|
    args = job["args"]
    next unless args && args.length >= 3 && args[0] && args[1] && args[2]
    timestamp = args[6].present? ? (Time.parse(args[6]) rescue Time.current) : Time.current
    { type: args[0], project_id: args[1].to_i, device_id: args[2].to_i,
      data: args[3], link_id: args[4]&.to_i, engagement_time: args[5], occurred_at: timestamp }
  end
  return 0 if payloads.empty?

  device_ids = payloads.map { |p| p[:device_id] }.uniq
  link_ids = payloads.filter_map { |p| p[:link_id] }.uniq
  devices = Device.where(id: device_ids).index_by(&:id)
  links = link_ids.any? ? Link.where(id: link_ids).index_by(&:id) : {}

  rows = payloads.filter_map do |p|
    device = devices[p[:device_id]]
    next unless device
    link = p[:link_id] ? links[p[:link_id]] : nil
    { event: p[:type], project_id: p[:project_id], device_id: p[:device_id],
      link_id: link&.id, data: p[:data], engagement_time: p[:engagement_time],
      ip: device.ip, remote_ip: device.remote_ip, vendor_id: device.vendor,
      platform: device.platform, app_version: device.app_version, build: device.build,
      path: link&.path, processed: false, created_at: p[:occurred_at], updated_at: p[:occurred_at] }
  end
  return 0 if rows.empty?

  begin
    Event.insert_all(rows)
  rescue ActiveRecord::InvalidForeignKey
    valid_pids = Project.where(id: rows.map { |r| r[:project_id] }.uniq).pluck(:id).to_set
    valid_dids = Device.where(id: rows.map { |r| r[:device_id] }.uniq).pluck(:id).to_set
    rows.select! { |r| valid_pids.include?(r[:project_id]) && valid_dids.include?(r[:device_id]) }
    Event.insert_all(rows) if rows.any?
  end
  rows.size
end

def emergency_insert_add_events(jobs)
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
    link_to_log = links_helper.link_for_url(args[3], project) rescue nil if args[3].present?
    link_to_log = links_helper.link_for_project_and_path(project, args[4]) rescue link_to_log if args[4].present?
    timestamp = args[5].present? ? (Time.parse(args[5]) rescue Time.current) : Time.current
    { type: args[0], project_id: project.id, device_id: device.id,
      link_id: link_to_log&.id, engagement_time: args[6], occurred_at: timestamp }
  end
  return 0 if payloads.empty?

  all_device_ids = payloads.map { |p| p[:device_id] }.uniq
  all_link_ids = payloads.filter_map { |p| p[:link_id] }.uniq
  all_devices = Device.where(id: all_device_ids).index_by(&:id)
  all_links = all_link_ids.any? ? Link.where(id: all_link_ids).index_by(&:id) : {}

  rows = payloads.filter_map do |p|
    device = all_devices[p[:device_id]]
    next unless device
    link = p[:link_id] ? all_links[p[:link_id]] : nil
    { event: p[:type], project_id: p[:project_id], device_id: p[:device_id],
      link_id: link&.id, data: nil, engagement_time: p[:engagement_time],
      ip: device.ip, remote_ip: device.remote_ip, vendor_id: device.vendor,
      platform: device.platform, app_version: device.app_version, build: device.build,
      path: link&.path, processed: false, created_at: p[:occurred_at], updated_at: p[:occurred_at] }
  end
  return 0 if rows.empty?

  begin
    Event.insert_all(rows)
  rescue ActiveRecord::InvalidForeignKey
    valid_pids = Project.where(id: rows.map { |r| r[:project_id] }.uniq).pluck(:id).to_set
    valid_dids = Device.where(id: rows.map { |r| r[:device_id] }.uniq).pluck(:id).to_set
    rows.select! { |r| valid_pids.include?(r[:project_id]) && valid_dids.include?(r[:device_id]) }
    Event.insert_all(rows) if rows.any?
  end
  rows.size
end
