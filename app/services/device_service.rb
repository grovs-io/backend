class DeviceService

  DeviceAttributes = Struct.new(
    :vendor, :user_agent, :model, :build, :app_version, :platform,
    :screen_width, :screen_height, :timezone, :webgl_vendor, :webgl_renderer, :language,
    keyword_init: true
  )

  class << self
    def authenticate_visitor(request, project, attrs)
      device = device_for(request, attrs.vendor, attrs.user_agent, project.id)

      if device
        visitor = Visitor.find_or_create_by!(device: device, project: project)
        DeviceUpdateService.set_device_data_async(device, request, attrs)
        visitor
      else
        device = DeviceCreationService.create_new_device(request, project, attrs)
        device.visitor_for_project_id(project.id)
      end
    end

    delegate :create_new_device, to: :DeviceCreationService

    def device_for(request, vendor, user_agent, project_id)
      device = nil

      linkedsquared_id = request.headers['LINKSQUARED'] || request.headers['linksquared']

      if linkedsquared_id
        visitor = Visitor.fetch_by_hash_id(linkedsquared_id, project_id)
        device = visitor.device if visitor
      end

      if !device && vendor
        device = Device.redis_find_by(:vendor, vendor)
      end

      if device
        DeviceUpdateService.update_device(device, request, user_agent)
      end

      device
    end

    def device_for_website_visit(request, response, project)
      cookie = CookieService.get_cookie_from_request(request)
      device = Device.fetch_by_hash_id(cookie)

      user_agent = request.user_agent

      device ||= device_for(request, nil, user_agent, project.id)

      device ||= DeviceCreationService.build_new_device(request, project, nil)

      CookieService.set_cookie_to_response(response, device.hashid)

      visitor = Visitor.find_or_create_by!(device: device, project: project)
      unless visitor.web_visitor
        visitor.web_visitor = true
        visitor.save!
      end

      DeviceUpdateService.update_device_sync(device, request, nil)

      device
    end

    def match_device_by_fingerprint_request(request, user_agent, project, current_device)
      FingerprintingService.match_device_for_project(request, user_agent, project, current_device)
    end

    delegate :update_device, to: :DeviceUpdateService

    def merge_visitor_events_and_device(from_device, to_device, project)
      return if from_device.id == to_device.id

      # Prevent bidirectional race: A→B and B→A can't both proceed.
      # Canonical sorted pair ensures only one direction wins.
      pair = [from_device.id, to_device.id].sort.join(':')
      pair_key = "merge_pair:#{pair}:#{project.id}"
      return unless REDIS.set(pair_key, "1", nx: true, ex: 300)

      set_key     = "#{CoalescedMergeJob::SET_PREFIX}:#{to_device.id}:#{project.id}"
      pending_key = "#{CoalescedMergeJob::PENDING_PREFIX}:#{to_device.id}:#{project.id}"

      REDIS.sadd?(set_key, from_device.id.to_s)
      REDIS.expire(set_key, 86_400) # 24h safety net — orphaned sets self-clean
      return unless REDIS.set(pending_key, "1", nx: true, ex: 60)

      CoalescedMergeJob.perform_async(to_device.id, project.id)
    end

  end

end
