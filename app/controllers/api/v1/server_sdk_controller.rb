class Api::V1::ServerSdkController < Api::V1::ProjectsBaseController
  include CustomRedirectsHandler
  include SdkLinkBuilder
  include Api::V1::Concerns::AnalyticsRetentionGate

  before_action :authenticate_request, except: []

  API_KEY_USED_TTL = 24.hours

  def generate_link
    link = build_and_save_sdk_link(platform_name: "API")

    render json: {link: link.access_path}, status: :ok
  end

  def link_details
    domain = @project.domain_for_project

    link = Link.includes(:custom_redirects, :domain).find_by(path: path_param, domain_id: domain.id)
    unless link
      render json: {error: "Link not found"}, status: :not_found
      return
    end


    render json: {link: LinkSerializer.serialize(link)}, status: :ok
  end

  def metrics_for_link
    domain = @project.domain_for_project
    link = Link.includes(:custom_redirects, :domain).find_by(path: path_param, domain_id: domain.id)
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

  private

  def authenticate_request
    @project_key = request.headers['PROJECT-KEY'] || request.headers['project-key']
    @environment = request.headers['ENVIRONMENT'] || request.headers['environment']

    # Check if project key is missing
    if @project_key.blank?
      render json: { error: "Missing PROJECT-KEY in headers" }, status: :bad_request
      return false
    end

    instance = Instance.find_by(api_key: @project_key)

    # Validate environment
    unless %w[production test].include?(@environment)
      audit_api_key_failure(instance)
      render json: { error: "Invalid ENVIRONMENT value. Allowed: 'production', 'test'" }, status: :bad_request
      return false
    end

    @project = instance&.public_send(@environment == "test" ? :test : :production)

    unless @project
      audit_api_key_failure(instance)
      render json: { error: "Invalid credentials" }, status: :forbidden
      return false
    end

    Current.actor = AuditActor.api_key(instance)
    audit_api_key_use(instance)
    true
  end

  def audit_api_key_failure(instance)
    return unless instance

    audit_api_key_once_per_day(instance, "audit:api_key_failed", "api_key.auth_failed", "failure")
  end

  def audit_api_key_use(instance)
    audit_api_key_once_per_day(instance, "audit:api_key_used", "api_key.used", "success")
  end

  # First sighting of (key, ip) per day (ADR 0002). SET NX claims the slot atomically; a failed write releases it.
  def audit_api_key_once_per_day(instance, prefix, action, outcome)
    return unless instance.audit_log_enabled?

    key = "#{prefix}:#{instance.id}:#{request.remote_ip}"
    claimed = begin
      REDIS.with { |c| c.set(key, "1", nx: true, ex: API_KEY_USED_TTL.to_i) }
    rescue Redis::BaseError
      true
    end
    return unless claimed

    begin
      Audit.record(instance_id: instance.id, action: action, outcome: outcome, actor: AuditActor.api_key(instance),
                        target: Audit.target_for(instance))
    rescue StandardError
      begin
        REDIS.with { |c| c.del(key) }
      rescue Redis::BaseError
        nil
      end
      raise
    end
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