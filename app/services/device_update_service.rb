class DeviceUpdateService
  class << self
    def update_device(device, request, user_agent)
      request_ip = request.ip
      request_remote_ip = request.remote_ip
      effective_ua = user_agent.presence || request.user_agent

      if device.ip == request_ip &&
         device.remote_ip == request_remote_ip &&
         device.user_agent == effective_ua
        # Nothing changed but keep device fresh for fingerprint ordering
        device.update_column(:updated_at, Time.current) if device.updated_at < 1.minute.ago
        return
      end

      # Dedup: skip if a basic-update job is already pending for this device
      return unless REDIS.set("dev_upd_basic:#{device.id}", "1", nx: true, ex: 300)

      UpdateDeviceJob.perform_async(device.id, request_ip, request_remote_ip, user_agent, request.user_agent)
    end

    def update_device_sync(device, request, user_agent)
      request_ip = request.ip
      request_remote_ip = request.remote_ip
      request_user_agent = request.user_agent

      return unless device

      device.assign_attributes(
        ip: request_ip,
        remote_ip: request_remote_ip,
        updated_at: Time.current
      )

      device.user_agent = user_agent.presence || request_user_agent
      device.save!
    end

    def set_device_data_async(device, request, attrs)
      request_ip = request.ip
      request_remote_ip = request.remote_ip
      effective_ua = attrs.user_agent.presence || request.user_agent

      return if device.ip == request_ip &&
                device.remote_ip == request_remote_ip &&
                device.user_agent == effective_ua &&
                (attrs.model.blank? || device.model == attrs.model) &&
                (attrs.build.blank? || device.build == attrs.build) &&
                (attrs.app_version.blank? || device.app_version == attrs.app_version) &&
                (attrs.platform.blank? || device.platform == attrs.platform) &&
                (attrs.vendor.blank? || device.vendor == attrs.vendor) &&
                (attrs.screen_width.blank? || device.screen_width.to_s == attrs.screen_width.to_s) &&
                (attrs.screen_height.blank? || device.screen_height.to_s == attrs.screen_height.to_s) &&
                (attrs.timezone.blank? || device.timezone == attrs.timezone) &&
                (attrs.language.blank? || device.language == attrs.language)

      # Dedup: skip if a full-update job is already pending for this device
      return unless REDIS.set("dev_upd_full:#{device.id}", "1", nx: true, ex: 300)

      UpdateDeviceJob.perform_async(device.id, request_ip, request_remote_ip, attrs.user_agent, request.user_agent,
            attrs.model, attrs.build, attrs.app_version, attrs.platform, attrs.vendor, attrs.screen_width,
            attrs.screen_height, attrs.timezone, attrs.webgl_vendor, attrs.webgl_renderer, attrs.language)
    end
  end
end
