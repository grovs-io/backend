class Api::V1::Mcp::BaseController < ApplicationController
  include McpAuthentication

  QUOTA_WARNING = begin
    msg = "Your Grovs usage has exceeded the free tier limit. Your deep links are not working."
    host = ENV["REACT_HOST"]
    if host.present?
      protocol = ENV.fetch("REACT_HOST_PROTOCOL", "https://")
      msg += " Subscribe at #{protocol}#{host} to restore service."
    end
    msg.freeze
  end

  private

  # Injects _warning into JSON responses when quota is exceeded.
  # Overrides render rather than using after_action to avoid re-parsing
  # the response body and mutating response.body (which conflicts with
  # streaming, compression middleware, and ETag generation).
  def render(options = nil, *args, &block)
    if options.is_a?(Hash) && options[:json].is_a?(Hash) && @instance&.quota_exceeded
      options[:json] = options[:json].merge(_warning: QUOTA_WARNING)
    end
    super
  end

  def load_mcp_project
    project_id = params.require(:project_id)
    project = Project.find_by_hashid(project_id)
    unless project
      render json: { error: "Project not found" }, status: :not_found
      return nil
    end

    unless InstanceRole.exists?(instance_id: project.instance_id, user_id: current_user.id)
      render json: { error: "Forbidden" }, status: :forbidden
      return nil
    end

    @instance = project.instance
    @project = project
  end

  def load_mcp_instance
    instance_id = params.require(:instance_id)
    instance = Instance.find_by_hashid(instance_id)
    unless instance
      render json: { error: "Instance not found" }, status: :not_found
      return nil
    end

    unless InstanceRole.exists?(instance_id: instance.id, user_id: current_user.id)
      render json: { error: "Forbidden" }, status: :forbidden
      return nil
    end

    @instance = instance
  end

  def parse_date_range
    @start_date = DateParamParser.call(params[:start_date], default: 30.days.ago)
    @end_date = DateParamParser.call(params[:end_date], default: Time.current)
  end
end
