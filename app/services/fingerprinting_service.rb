class FingerprintingService
  class << self
    # Cache a device with minimal operations and maximum speed
    def cache_device(device, request, project_id)
      timestamp = Time.current.to_i
      
      # Create minimal data structure - use a unique member ID that includes all needed information
      # Format: device_id:project_id:timestamp
      key = fingerprint_key(request.ip, request.remote_ip)
      Rails.logger.debug("Caching device #{device.id} for project #{project_id} at #{timestamp} in key #{key}")
      
      member = "#{device.id}:#{project_id}:#{timestamp}"
      ttl = Grovs::Links::VALIDITY_MINUTES * 60
      index_key = reverse_index_key(device.id, project_id)

      # Pipeline all 4 independent writes into a single round-trip
      redis.with do |conn|
        conn.pipelined do |p|
          p.zadd(key, timestamp, member)
          p.expire(key, ttl)
          p.sadd?(index_key, key)
          p.expire(index_key, ttl)
        end
      end
    end
    
    # Optimized find_devices with minimal parsing
    def find_devices(request, project_id)
      key = fingerprint_key(request.ip, request.remote_ip)
      min_score = Grovs::Links::VALIDITY_MINUTES.minutes.ago.to_i
      
      # Pipeline cleanup + fetch into a single round-trip
      _, cached_members = redis.with do |conn|
        conn.pipelined do |p|
          p.zremrangebyscore(key, '-inf', min_score - 1)
          p.zrangebyscore(key, min_score, '+inf')
        end
      end
      cached_members ||= []
      return Device.none if cached_members.empty?
      
      # Fast string parsing without JSON overhead
      device_ids = cached_members.each_with_object([]) do |member, ids|
        parts = member.split(':')
        ids << parts[0].to_i if parts[1].to_s == project_id.to_s
      end.uniq
      
      # Use IN query for bulk loading
      Device.where(id: device_ids).order('updated_at DESC')
    end
    
    def match_device_for_project(request, user_agent, project, current_device)
      devices = find_devices(request, project.id)

      return nil if devices.empty?
      
      # Use optimized device matching
      matching_devices = match_devices(devices.to_a, user_agent, current_device)
      
      # Handle single match case
      if matching_devices.count == 1
        device_to_return = matching_devices[0]
        # Use background job for removal to keep response time fast
        remove_device_from_cache_by_id(device_to_return.id, project.id)

        device_to_return
      end
    end
    
    # High-performance cache removal with minimal operations
    def remove_device_from_cache_by_id(device_id, project_id)
      # Get all fingerprint keys this device is stored in (need result, stays sequential)
      index_key = reverse_index_key(device_id, project_id)
      fingerprint_keys = redis.smembers(index_key) || []
      return if fingerprint_keys.empty?

      device_pattern = "#{device_id}:#{project_id}:"

      # Phase 1: Pipeline all ZRANGE calls to fetch members
      all_members = redis.with do |conn|
        conn.pipelined do |p|
          fingerprint_keys.each { |key| p.zrange(key, 0, -1) }
        end
      end

      # Phase 2: Pipeline all ZREM calls + DEL of the reverse index
      redis.with do |conn|
        conn.pipelined do |p|
          fingerprint_keys.each_with_index do |key, i|
            members = all_members[i] || []
            matching = members.select { |m| m.start_with?(device_pattern) }
            p.zrem(key, matching) if matching.any?
          end
          p.del(index_key)
        end
      end
    end
    
    private
    
    def redis
      REDIS
    end
    
    def fingerprint_key(request_ip, remote_ip)
      "fp:#{remote_ip}:#{remote_ip}"
    end
    
    def reverse_index_key(device_id, project_id)
      "di:#{device_id}:#{project_id}"
    end
    
    # Optimized match_devices with caching for browser objects
    def match_devices(devices, user_agent, current_device)
      matched_devices_by_ua = match_devices_by_user_agent(devices, user_agent)
      if matched_devices_by_ua.count < 2
        return matched_devices_by_ua
      end

      # We have a collision, try to fix it by looking at extra data
      filter_devices_by_extra_info(matched_devices_by_ua, current_device)

      
    end

    def filter_devices_by_extra_info(devices, current_device)
      return [] unless devices
  
      # Define which fields to compare
      comparison_fields = [
        :screen_width, 
        :screen_height, 
        :timezone, 
        :webgl_vendor, 
        :webgl_renderer, 
        :language
      ]
      
      # Only include devices that exactly match current_device on all specified fields
      devices.select do |device|
        comparison_fields.all? do |field|
          next false unless current_device.respond_to?(field) && device.respond_to?(field)

          current_value = current_device.send(field)
          device_value = device.send(field)

          next false if current_value.nil? || device_value.nil?

          device_value.to_s == current_value.to_s
        end
      end
    end

    def match_devices_by_user_agent(devices, user_agent)
      received_ua = Browser.new(user_agent)
      # Extract key properties once to avoid repeated calls
      received_platform_name = received_ua.platform.name
      received_platform_version = received_ua.platform.version
      received_webkit_version = received_ua.webkit_full_version
      received_full_version = received_ua.full_version
      
      devices.select do |device|
        
        current_ua = Browser.new(device.user_agent)
        
        # Compare platform first (fast fail)
        next false unless current_ua.platform.name == received_platform_name &&
                        current_ua.platform.version == received_platform_version

        # Compare version based on browser type
        if current_ua.webkit? && (current_ua.platform.ios? || current_ua.platform.mac?)
          current_ua.webkit_full_version == received_webkit_version
        else
          current_ua.full_version == received_full_version
        end
      rescue StandardError => e
        # Minimal logging for performance
        device.user_agent == user_agent
        
      end

      
    end

  end
end