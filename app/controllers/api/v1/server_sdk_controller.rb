class Api::V1::ServerSdkController < Api::V1::ProjectsBaseController
  include CustomRedirectsHandler
  include SdkLinkBuilder

  before_action :authenticate_request, except: []

  def generate_link
    link = build_and_save_sdk_link(platform_name: "API")

    render json: {link: link.access_path}, status: :ok
  end

  def link_details
    domain = @project.domain_for_project

    link = Link.find_by(path: path_param, domain_id: domain.id)
    unless link
      render json: {error: "Link not found"}, status: :not_found
      return
    end


    render json: {link: LinkSerializer.serialize(link)}, status: :ok
  end

  def metrics_for_link
    domain = @project.domain_for_project
    link = Link.find_by(path: path_param, domain_id: domain.id)
    unless link
      render json: {error: "Link not found"}, status: :not_found
      return
    end

    metrics = LinkStatisticsQuery.new(params: { link_id: link.id, sort_by: 'views', start_date: Time.at(0).to_date, active: link.active }, 
project: @project).call[:links][0]
    render json: {metrics: metrics}
  end

  def metrics_for_project
    metrics = LinkStatisticsQuery.new(params: { all: true, sort_by: 'views', start_date: Time.at(0).to_date, active: "true" }, 
project: @project).call[:links]
    render json: metrics
  end

  private

  def authenticate_request
    @project_key = request.headers['PROJECT-KEY'] || request.headers['project-key']
    @environment = request.headers['ENVIRONMENT'] || request.headers['environment']

    # Check if project key is missing
    if @project_key.blank?
      render json: { error: "Missing PROJECT-KEY in headers" }, status: :bad_request
      return false
    end

    # Validate environment
    unless %w[production test].include?(@environment)
      render json: { error: "Invalid ENVIRONMENT value. Allowed: 'production', 'test'" }, status: :bad_request
      return false
    end

    # Look up instance by api_key, then find the correct project by environment
    instance = Instance.find_by(api_key: @project_key)
    @project = instance&.public_send(@environment == "test" ? :test : :production)

    unless @project
      render json: { error: "Invalid credentials" }, status: :forbidden
      return false
    end

    true
  end

  # Params

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

  def id_param
    params.require(:id)
  end

  def path_param
    params.require(:path)
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