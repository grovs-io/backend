class Api::V1::Mcp::BaseController < ApplicationController
  include McpAuthentication
  include McpQuotaWarning
  include Api::V1::Concerns::CampaignIdParam

  private

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
