class Api::V1::LinksController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  include CustomRedirectsHandler
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project
  before_action :validate_campaign_id, only: [:create_link, :update_link]

  def current_project_links_v2
    result = LinkStatisticsQuery.new(params: params, project: @project, campaign_id: campaign_id_param).call
    render json: result, status: :ok
  end

  def links_by_ids
    domain = domain_for_current_project
    return unless domain

    links = domain.links.where(id: ids_param).includes(:custom_redirects, :domain, image_attachment: :blob)
    render json: { links: LinkSerializer.serialize(links) }
  end

  def create_link
    link = link_service(@project).create(
      link_attrs: link_params,
      tags: tags_param,
      data: data_param,
      image: image_param,
      image_url: image_url_param,
      campaign_id: campaign_id_param,
      custom_redirects: custom_redirect_params
    )

    render json: { link: LinkSerializer.serialize(link) }, status: :ok
  rescue ArgumentError => e
    render json: { error: e.message }, status: :bad_request
  rescue ActiveRecord::RecordNotFound => e
    render json: { error: e.message }, status: :not_found
  end

  def update_link
    link = link_for_param
    return unless link

    updated = link_service(@project).update(
      link: link,
      link_attrs: link_params,
      tags: tags_param,
      data: data_param,
      image: image_param,
      campaign_id: campaign_id_param,
      custom_redirects: custom_redirect_params
    )

    render json: { link: LinkSerializer.serialize(updated) }, status: :ok
  rescue ArgumentError => e
    render json: { error: e.message }, status: :bad_request
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def remove_link
    link = link_for_param
    return unless link

    link_service(@project).archive(link: link)
    render json: { message: "Link deleted!" }, status: :ok
  end

  def is_path_available
    domain = domain_for_current_project
    return unless domain

    available = link_service(@project).path_available?(path: path_param, domain: domain)
    render json: { available: available }, status: :ok
  end

  def generate_path
    domain = domain_for_current_project
    return unless domain

    result = link_service(@project).generate_path(domain: domain)
    render json: result, status: :ok
  end

  # OLD API Calls

  def current_project_links
    links = links_for_search_params
    return unless links

    links = links.includes(:custom_redirects, :domain, image_attachment: :blob)
    render json: PaginatedResponse.new(links, data: LinkSerializer.serialize(links)), status: :ok
  end

  private

  def link_service(project)
    LinkManagementService.new(project: project)
  end

  def custom_redirect_params
    {
      ios: ios_custom_redirect_param,
      android: android_custom_redirect_param,
      desktop: desktop_custom_redirect_param
    }
  end

  def link_for_param
    find_authorized_resource(Link, link_id_param) { |link| link.domain.project_id == @project.id }
  end

  def validate_campaign_id
    value = params.permit(:campaign_id)[:campaign_id]
    return if value.nil?
    if Integer(value, exception: false).nil?
      render json: { error: "campaign_id must be an integer" }, status: :bad_request
    end
  end

  # Params

  def image_url_param
    params.permit(:image_url)[:image_url]
  end

  def link_id_param
    params.require(:link_id)
  end

  def image_param
    params.permit(:image)[:image]
  end

  def link_params
    params.permit(:show_preview_ios, :show_preview_android, :name, :title, :subtitle, :path, :image_url, :ads_platform, :tracking_campaign,
:tracking_medium, :tracking_source)
  end

  def tags_param
    params.permit(:tags)[:tags]
  end

  def data_param
    params.permit(:data)[:data]
  end

  def path_param
    params.require(:path)
  end

  def ids_param
    params.require(:ids)
  end

end
