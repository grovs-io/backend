class Api::V1::ServerSdkController < Api::V1::ProjectsBaseController
  include CustomRedirectsHandler
  include SdkLinkBuilder
  include Api::V1::Concerns::AnalyticsRetentionGate
  include ServerKeyAuthentication
  wrap_parameters false

  before_action :authenticate_request, except: []

  def generate_link
    link = build_and_save_sdk_link(platform_name: "API")

    render json: {link: link.access_path}, status: :ok
  end

  def link_details
    domain = @project.domain_for_project

    link = LinksService.find_link_preferring_active(domain.id, path_param)
    unless link
      render json: {error: "Link not found"}, status: :not_found
      return
    end


    render json: {link: LinkSerializer.serialize(link)}, status: :ok
  end

  def metrics_for_link
    domain = @project.domain_for_project
    link = LinksService.find_link_preferring_active(domain.id, path_param)
    unless link
      render json: {error: "Link not found"}, status: :not_found
      return
    end

    metrics = LinkStatisticsQuery.new(params: { link_id: link.id, sort_by: 'views', start_date: retention_floor(Time.at(0).to_date), active: link.active },
project: @project).call[:links][0]
    render json: {metrics: metrics}
  end

  def metrics_for_project
    metrics = LinkStatisticsQuery.new(params: { all: true, sort_by: 'views', start_date: retention_floor(Time.at(0).to_date), active: "true" },
project: @project).call[:links]
    render json: metrics
  end

  def push
    unless @project.instance.push_api_enabled?
      return render json: { error: "Push campaigns need an enterprise plan", error_code: "enterprise_required" }, status: :forbidden
    end

    status, payload = PushCampaignGateway.create(project: @project, params: params.except(:controller, :action, :format))
    case status
    when :ok then render json: { campaign: payload }, status: :accepted
    when :invalid then render json: { error: payload }, status: :unprocessable_entity
    when :rate_limited then render json: { error: payload, error_code: "rate_limited" }, status: :too_many_requests
    else render json: { error: "Not found" }, status: :not_found
    end
  end

  def push_status
    unless @project.instance.push_api_enabled?
      return render json: { error: "Push campaigns need an enterprise plan", error_code: "enterprise_required" }, status: :forbidden
    end

    campaign = PushCampaignGateway.report(project: @project, id: params[:campaign_id])
    return render json: { error: "Not found" }, status: :not_found if campaign.nil? || campaign == :unavailable

    render json: { campaign: campaign }, status: :ok
  end

  private

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

  def copy_to_clipboard_ios_param
    params.permit(:copy_to_clipboard_ios)[:copy_to_clipboard_ios]
  end

  def copy_to_clipboard_android_param
    params.permit(:copy_to_clipboard_android)[:copy_to_clipboard_android]
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