class Api::V1::Sdk::LinksController < Api::V1::Sdk::BaseController
  include CustomRedirectsHandler
  include SdkLinkBuilder

  def data_for_device_details
    result = build_link_data_service.resolve_by_fingerprint(request, user_agent_param)
    render json: result, status: :ok
  end

  def data_for_device_details_and_url
    link = LinksService.link_for_url(url_param, @project)
    result = build_link_data_service.resolve_for_link(link, request, user_agent_param)
    render json: result, status: :ok
  end

  def data_for_device_details_and_path
    link = LinksService.link_for_project_and_path(@project, path_param)
    result = build_link_data_service.resolve_for_link(link, request, user_agent_param)
    render json: result, status: :ok
  end

  def link_details
    link = Link.find_by(domain_id: @project.domain.id, path: path_param)
    unless link
      render json: nil
      return
    end

    render json: LinkSerializer.serialize(link)
  end

  def create_link
    link = build_and_save_sdk_link(
        platform_name: @platform,
        visitor: @visitor,
        image_url: image_url_param,
        image: image_param
    )

    render json: {link: link.access_path}, status: :ok
  end

  private

  def build_link_data_service
    SdkLinkDataService.new(
      project: @project, device: @device, platform: @platform
    )
  end

  def user_agent_param
    params.require(:user_agent)
  end

  def url_param
    params.require(:url)
  end

  def path_param
    params.require(:path)
  end

  def image_url_param
    params.permit(:image_url)[:image_url]
  end

  def title_param
    params.permit(:title)[:title]
  end

  def subtitle_param
    params.permit(:subtitle)[:subtitle]
  end

  def data_param
    params.permit(:data)[:data]
  end

  def tags_param
    params.permit(:tags)[:tags]
  end

  def image_param
    params.permit(:image)[:image]
  end

  def show_preview_param
    params.permit(:show_preview)[:show_preview]
  end

  def show_preview_ios_param
    params.permit(:show_preview_ios)[:show_preview_ios]
  end

  def show_preview_android_param
    params.permit(:show_preview_android)[:show_preview_android]
  end

  def tracking_campaign_param
    params.permit(:tracking_campaign)[:tracking_campaign]
  end

  def tracking_medium_param
    params.permit(:tracking_medium)[:tracking_medium]
  end

  def tracking_source_param
    params.permit(:tracking_source)[:tracking_source]
  end
end
