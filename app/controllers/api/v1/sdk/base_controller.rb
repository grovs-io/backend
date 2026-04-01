class Api::V1::Sdk::BaseController < Api::V1::ProjectsBaseController
  before_action :authenticate_request
  before_action :authenticate_device

  private

  def authenticate_request
    @project_key = request.headers['PROJECT-KEY'] || request.headers['project-key']
    @platform = request.headers['PLATFORM'] || request.headers['platform']
    @identifier = request.headers['IDENTIFIER'] || request.headers['identifier']

    # Early return if headers are missing
    unless @project_key && @platform && @identifier
      render json: {error: "Missing credentials"}, status: :forbidden
      return false
    end

    @project = Project.redis_find_by(:identifier, @project_key, includes: :instance)

    if @project.nil?
      render json: {error: "Invalid credentials"}, status: :forbidden
      return false
    end

    application = @project.instance.application_for_platform(@platform)
    unless application
      render json: {error: "The app is not configured, grovs won't function!"}, status: :forbidden
      return false
    end

    config = application.configuration
    unless config
      render json: {error: "The app redirect config is not set, grovs won't function!"}, status: :forbidden
      return false
    end

    if @platform == Grovs::Platforms::ANDROID && @identifier != config.identifier
      render json: {error: "This Android app is not configured, grovs won't function!"}, status: :unprocessable_entity
      return false
    end

    if @platform == Grovs::Platforms::IOS && @identifier != config.bundle_id
      render json: {error: "This iOS app is not configured, grovs won't function!"}, status: :unprocessable_entity
      return false
    end

    if @platform == Grovs::Platforms::WEB && !config.web_configuration_linked_domains&.map(&:domain)&.include?(@identifier)
      render json: {error: "This Web app is not configured, grovs won't function!"}, status: :unprocessable_entity
      return false
    end

    true
  end

  def authenticate_device
    linkedsquared_id = request.headers['LINKSQUARED'] || request.headers['linksquared']
    @device = nil

    if linkedsquared_id
      @visitor = Visitor.fetch_by_hash_id(linkedsquared_id, nil)
      if @visitor
        @device = @visitor.device
      end
    end

    unless @device
      render json: {error: "Invalid linksquared id"}, status: :forbidden
      return false
    end

    # Update device
    DeviceService.update_device(@device, request, optional_user_agent_param)

    true
  end

  def vendor_param
    params.permit(:vendor_id)[:vendor_id]
  end

  def optional_user_agent_param
    params.permit(:user_agent)[:user_agent]
  end
end
