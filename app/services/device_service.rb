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
      MergeVisitorEventsJob.perform_async(from_device.id, to_device.id, project.id)
    end

    private

    def build_new_device(request, project, platform, vendor: nil, user_agent: nil)
      DeviceCreationService.build_new_device(request, project, platform, vendor: vendor, user_agent: user_agent)
    end

    def update_device_with_full_data(device, request, vendor, model, build, app_version, platform, **kwargs)
      DeviceCreationService.update_device_with_full_data(device, request, vendor, model, build, app_version, platform, **kwargs)
    end

    def generate_vendor_id
      DeviceCreationService.generate_vendor_id
    end

    def match_devices(devices, user_agent)
      received_ua = Browser.new(user_agent)

      devices.select do |device|
        current_ua = Browser.new(device.user_agent)

        platform_name_same = current_ua.platform.name == received_ua.platform.name
        platform_version_same = current_ua.platform.version == received_ua.platform.version

        next false unless platform_name_same && platform_version_same

        if current_ua.webkit?
          current_ua.webkit_full_version == received_ua.webkit_full_version
        else
          current_ua.full_version == received_ua.full_version
        end
      end
    end
  end

end
