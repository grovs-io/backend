class Api::V1::Sdk::SmartBannersController < Api::V1::Sdk::BaseController
  wrap_parameters false
  before_action :require_web

  def index
    render json: { smart_banners: SmartBanner.sdk_payload_for(@project) }, status: :ok
  end

  def link
    banner = @project.smart_banners.live.find(params.require(:banner_id))
    link = SmartBannerLinkService.fetch(banner, page_path: params[:page_path], data: data_param,
                                                 client_ip: request.remote_ip)
    render json: { link: link.access_path }, status: :ok
  rescue SmartBannerLinkService::RateLimited
    response.headers["Retry-After"] = "60"
    render json: { error: "Too many new links for this banner from this IP — try again in a minute" },
           status: :too_many_requests
  rescue SmartBannerLinkData::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::InvalidForeignKey
    # The banner was deleted between the lookup and the link insert.
    render json: { error: "Couldn't find SmartBanner" }, status: :not_found
  end

  private

  def require_web
    return if @platform == Grovs::Platforms::WEB

    render json: { error: "Smart banners are web only" }, status: :unprocessable_entity
  end

  # Shape and limits are checked by SmartBannerLinkData, so the raw hash is passed through.
  def data_param
    raw = params[:data]
    raw.is_a?(ActionController::Parameters) ? raw.to_unsafe_h : raw
  end
end
