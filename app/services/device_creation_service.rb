class DeviceCreationService
  class << self
    def create_new_device(request, project, attrs)
      vendor = attrs.vendor || generate_vendor_id

      device = build_new_device(request, project, attrs.platform, vendor: vendor, user_agent: attrs.user_agent)
      update_device_with_full_data(device, request, vendor, attrs.model, attrs.build, attrs.app_version, attrs.platform,
        screen_width: attrs.screen_width, screen_height: attrs.screen_height, timezone: attrs.timezone,
        webgl_vendor: attrs.webgl_vendor, webgl_renderer: attrs.webgl_renderer, language: attrs.language)
    end

    def build_new_device(request, project, platform, vendor: nil, user_agent: nil)
      vendor ||= generate_vendor_id
      user_agent ||= request.user_agent
      language = request.env['HTTP_ACCEPT_LANGUAGE']&.split(',')&.first&.split(';')&.first

      device = Device.new(
        user_agent: user_agent,
        ip: request.ip,
        remote_ip: request.remote_ip,
        language: language,
        platform: platform || Device.new(user_agent: user_agent).user_agent_platform,
        vendor: vendor
      )

      visitor = Visitor.new(project: project, device: device)
      visitor.save!
      device.save!

      device
    end

    def update_device_with_full_data(device, request, vendor, model, build, app_version, platform,
                                     screen_width: nil, screen_height: nil, timezone: nil,
                                     webgl_vendor: nil, webgl_renderer: nil, language: nil)
      device.ip = request.ip
      device.remote_ip = request.remote_ip
      device.model = model
      device.build = build
      device.app_version = app_version
      device.platform = platform
      device.vendor = vendor if vendor
      device.screen_width = screen_width if screen_width
      device.screen_height = screen_height if screen_height
      device.timezone = timezone if timezone
      device.webgl_vendor = webgl_vendor if webgl_vendor
      device.webgl_renderer = webgl_renderer if webgl_renderer
      device.language = language if language

      device.save!
      device
    end

    def generate_vendor_id
      loop do
        token = SecureRandom.hex(32)
        break token unless Device.exists?(vendor: token)
      end
    end
  end
end
