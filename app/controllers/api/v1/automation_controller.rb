class Api::V1::AutomationController < Api::V1::ProjectsBaseController
  include Api::V1::Concerns::AnalyticsRetentionGate

  before_action :authenticate_request

  def metrics_for_user
    instance = Instance.find_by(api_key: key_param)
    unless instance
      render json: {error: "Key is invalid"}, status: :not_found
      return
    end

    project = instance.production
    if test_param
      project = instance.test
    end

    device = Device.redis_find_by(:vendor, vendor_id_param)
    unless device
      render json: {error: "Device is invalid"}, status: :not_found
      return
    end

    visitor = Visitor.redis_find_by_multiple_conditions({ device_id: device.id, project_id: project.id })
    unless visitor
      render json: {error: "Can not find visitor"}, status: :not_found
      return
    end

    # metrics = Visitor.count_own_visitor_events(project.id).where(id: visitor.id).as_json(skip_invites: true)
    @project = project
    floor = retention_floor(Time.at(0).to_date)
    metrics = VisitorStatisticsQuery.new(params: { visitor_id: visitor.id, sort_by: 'views', start_date: floor },
project: project).call[:visitors][0]
    number_of_links = Link.where(visitor_id: visitor.id, domain_id: project.domain.id).count
    aggregated_metrics = VisitorReferralStatisticsQuery.new(params: { visitor_id: visitor.id, sort_by: 'views', start_date: floor },
project: project).call[:visitors][0]

    render json: {
      visitor: VisitorSerializer.serialize(visitor, skip_invites: true),
      metrics: metrics,
      aggregated_metrics: aggregated_metrics,
      number_of_generated_links: number_of_links
    }, status: :ok
  end

  def details_for_link
    instance = Instance.find_by(api_key: key_param)
    unless instance
      render json: {error: "Key is invalid"}, status: :not_found
      return
    end

    project = instance.production
    if test_param
      project = instance.test
    end

    link = Link.includes(:custom_redirects, :domain).find_by(domain_id: project.domain.id, path: path_param)
    unless link
      render json: {link: nil, metrics: nil}
      return
    end


    @project = project
    metrics = LinkStatisticsQuery.new(params: { link_id: link.id, sort_by: 'views', start_date: retention_floor(Time.at(0).to_date), active: "true" },
project: project).call[:links][0]
    render json: {link: LinkSerializer.serialize(link), metrics: metrics}
  end

  private

  def authenticate_request
    x_auth = request.headers['X-AUTH']

    if ENV['ADMIN_API_KEY'].blank? || !ActiveSupport::SecurityUtils.secure_compare(x_auth.to_s, ENV['ADMIN_API_KEY'])
      render json: {error: "Invalid credentials"}, status: :forbidden
      return false
    end

    true
  end

  # Params

  def vendor_id_param
    params.require(:vendor_id)
  end

  def key_param
    params.require(:key)
  end

  def test_param
    params.require(:test)
  end

  def path_param
    params.require(:path)
  end

end