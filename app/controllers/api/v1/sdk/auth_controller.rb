class Api::V1::Sdk::AuthController < Api::V1::Sdk::BaseController
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

    render json: {linksquared: @visitor.hashid, uri_scheme: @project.instance.uri_scheme, sdk_identifier: @visitor.sdk_identifier,
sdk_attributes: @visitor.sdk_attributes, push_token: @device.push_token}
  end

  def device_for_vendor
    last_seen = nil

    device = Device.redis_find_by(:vendor, vendor_param)
    unless device
      render json: {last_seen: last_seen}, status: :ok
      return
    end

    latest_event = Event.select('DISTINCT ON (project_id, device_id) *')
                .where(project_id:  @project.id, device_id: device.id)
                .order(:project_id, :device_id, created_at: :desc)
                .first

    if latest_event
      last_seen = latest_event.created_at
    end

    render json: {last_seen: last_seen}, status: :ok
  end

  private

  def user_agent_param
    params.require(:user_agent)
  end

  def model_param
    params.permit(:model)[:model]
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
