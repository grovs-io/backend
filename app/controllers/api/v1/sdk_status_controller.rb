class Api::V1::SdkStatusController < Api::V1::ProjectsBaseController
  include DashboardAuthorization

  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project

  def show
    render json: ProjectSdkStatusService.call(@project), status: :ok
  end
end
