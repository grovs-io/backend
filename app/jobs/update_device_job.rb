class UpdateDeviceJob
  include Sidekiq::Job
  sidekiq_options queue: :device_updates, retry: 1

  def perform(device_id, request_ip, request_remote_ip, user_agent, request_user_agent, # rubocop:disable Metrics/ParameterLists
              model = nil, build = nil, app_version = nil,
              platform = nil, vendor = nil, screen_width = nil,
              screen_height = nil, timezone = nil, webgl_vendor = nil, webgl_renderer = nil, language = nil)
    device = Device.find_by(id: device_id)
    return unless device

    effective_ua = user_agent.presence || request_user_agent

    # Set user_agent on in-memory object so user_agent_platform computes correctly
    device.user_agent = effective_ua

    attrs = {
      ip: request_ip,
      remote_ip: request_remote_ip,
      user_agent: effective_ua,
      updated_at: Time.current
    }

    # Only include optional attributes if they're present
    optional = {
      model: model,
      build: build,
      app_version: app_version,
      platform: platform.presence || device.platform.presence || device.user_agent_platform,
      vendor: vendor,
      screen_width: screen_width,
      screen_height: screen_height,
      timezone: timezone,
      webgl_vendor: webgl_vendor,
      webgl_renderer: webgl_renderer,
      language: language
    }
    optional.each { |key, value| attrs[key] = value if value.present? }

    # Use update_columns to bypass after_commit callback, then clear cache manually.
    old_vendor = device.vendor if attrs.key?(:vendor) && device.vendor != attrs[:vendor]
    device.update_columns(attrs)
    keys = device.cache_keys_to_clear
    # Also clear old vendor key if vendor changed
    if old_vendor.present?
      prefix = Device.cache_prefix
      keys << "#{prefix}:find_by:vendor:#{old_vendor}:no_includes"
    end
    REDIS.del(*keys) if keys.present?
  end
end
