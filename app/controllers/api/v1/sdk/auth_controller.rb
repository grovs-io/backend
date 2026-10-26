class Api::V1::Sdk::AuthController < Api::V1::Sdk::BaseController
  # Must be >= DeviceUpdateService's touch throttle, or a live device still reads as never-seen.
  DEVICE_FRESH_WINDOW = 1.minute

  skip_before_action :authenticate_device

  def authenticate
    attrs = DeviceService::DeviceAttributes.new(
      vendor: vendor_param, user_agent: user_agent_param, model: model_param,
      build: build_param, app_version: app_version_param, platform: @platform,
      screen_width: screen_width_param, screen_height: screen_height_param,
      timezone: timezone_param, webgl_vendor: webgl_vendor_param,
      webgl_renderer: webgl_renderer_param, language: language_param
    )
    @visitor = DeviceService.authenticate_visitor(request, @project, attrs)
    @device = @visitor.device
    stamp_web_sdk_last_seen if @platform == Grovs::Platforms::WEB

    render json: {linksquared: @visitor.hashid, uri_scheme: @project.instance.uri_scheme, sdk_identifier: @visitor.sdk_identifier,
sdk_attributes: @visitor.sdk_attributes, push_token: @device.push_token,
has_smart_banners: has_smart_banners?}
  end

  def device_for_vendor
    # Without this a blank param matches an arbitrary NULL-vendor device (web visitors have none).
    return render json: {last_seen: nil}, status: :ok if vendor_param.blank?

    device = Device.redis_find_by(:vendor, vendor_param)

    render json: {last_seen: device && last_seen_for(device)}, status: :ok
  end

  private

  # Banners must never break web auth; any failure here reads as "no banners".
  def has_smart_banners?
    return false unless @platform == Grovs::Platforms::WEB

    SmartBanner.sdk_payload_for(@project).any?
  rescue StandardError => e
    Rails.logger.warn("has_smart_banners failed for project #{@project.id}: #{e.message}")
    false
  end

  # Redis NX caps it at one DB write per project per hour; never raises into the auth response.
  def stamp_web_sdk_last_seen
    return unless REDIS.set("smart_banners:web_sdk_seen:#{@project.id}", "1", nx: true, ex: 3600)

    Project.where(id: @project.id)
           .where("web_sdk_last_seen_at IS NULL OR web_sdk_last_seen_at < ?", 1.hour.ago)
           .update_all(web_sdk_last_seen_at: Time.current)
  rescue StandardError => e
    Rails.logger.warn("stamp_web_sdk_last_seen failed for project #{@project.id}: #{e.message}")
  end

  # devices.updated_at is global, so it only answers once a Visitor proves this device was here.
  def last_seen_for(device)
    return Event.where(project_id: @project.id, device_id: device.id).maximum(:created_at) unless Clickhouse.primary?

    stamped = DeviceLastSeen.where(project_id: @project.id, device_id: device.id).pick(:last_seen_at)
    return stamped if stamped
    return nil unless Visitor.exists?(project_id: @project.id, device_id: device.id)
    return nil if device.updated_at - device.created_at < DEVICE_FRESH_WINDOW

    device.updated_at
  end

  def user_agent_param
    params.require(:user_agent)
  end

  # The mobile SDKs send the device model as `device`; `model` is kept for other callers.
  # Raw hardware identifiers are mapped to marketing names server-side so a new device
  # is a table/CSV entry here, not an SDK release.
  def model_param
    permitted = params.permit(:model, :device)
    raw = permitted[:model].presence || permitted[:device]

    if @platform == Grovs::Platforms::ANDROID
      AndroidDeviceModels.humanize(raw)
    else
      AppleDeviceModels.humanize(raw)
    end
  end

  def build_param
    params.permit(:build)[:build]
  end

  def app_version_param
    params.require(:app_version)
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
