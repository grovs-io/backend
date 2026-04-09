class Api::V1::Mcp::ProjectsController < Api::V1::Mcp::BaseController
  # POST /api/v1/mcp/projects
  def create
    name = params.require(:name)
    service = InstanceProvisioningService.new(current_user: current_user)
    instance = service.create(name: name)

    render json: { instance: InstanceSerializer.serialize(instance) }, status: :created
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :bad_request
  end
end
