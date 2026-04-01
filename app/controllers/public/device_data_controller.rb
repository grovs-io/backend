class Public::DeviceDataController < Public::BaseController
  skip_before_action :verify_authenticity_token, only: [:store_device_data]

  def store_device_data
    device_hash_id = CookieService.get_cookie_from_request(request)
    return unless device_hash_id

    device = Device.fetch_by_hash_id(device_hash_id)
    return unless device

    update_device_fingerprint(device)
    recache_device_if_needed(device)
  end

  private

  def update_device_fingerprint(device)
    device.screen_width = screen_width_param if screen_width_param.present?
    device.screen_height = screen_height_param if screen_height_param.present?
    device.timezone = timezone_param if timezone_param.present?
    device.webgl_vendor = webgl_vendor_param if webgl_vendor_param.present?
    device.webgl_renderer = webgl_renderer_param if webgl_renderer_param.present?
    device.language = language_param if language_param.present?
    device.save! if device.changed?
  end

  def recache_device_if_needed(device)
    domain = Domain.redis_find_by_multiple_conditions({ domain: request.domain, subdomain: request.subdomain })
    FingerprintingService.cache_device(device, request, domain.project_id) if domain
  end

  def screen_width_param
    params.permit(:screen_width)[:screen_width]
  end

  def screen_height_param
    params.permit(:screen_height)[:screen_height]
  end

  def timezone_param
    params.permit(:timezone)[:timezone]
  end

  def webgl_vendor_param
    params.permit(:webgl_vendor)[:webgl_vendor]
  end

  def webgl_renderer_param
    params.permit(:webgl_renderer)[:webgl_renderer]
  end

  def language_param
    params.permit(:language)[:language]
  end
end
