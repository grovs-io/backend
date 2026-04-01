class Api::V1::ExportController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project, only: [:export_link_data]
  before_action :load_instance, only: [:export_usage_data]

  def export_link_data
    safe_params = {
      "active" => ActiveModel::Type::Boolean.new.cast(params[:active]),
      "sdk" => ActiveModel::Type::Boolean.new.cast(params[:sdk]),
      "start_date" => params[:start_date].presence,
      "end_date" => params[:end_date].presence,
      "campaign_id" => params[:campaign_id].presence
    }.compact

    # Queue the job
    ExportLinkDataJob.perform_async(
      @project.id,
      safe_params,
      current_user.id
    )

    render json: { message: "Export job has been queued. You will be notified when it's ready." }, status: :accepted
  end

  def export_usage_data
    safe_params = {
      "start_date" => params[:start_date].presence,
      "end_date" => params[:end_date].presence,
    }.compact

    ExportActivityDataJob.perform_async(
      @instance.id,
      safe_params,
      current_user.id
    )

    render json: { message: "Export job has been queued. You will be notified when it's ready." }, status: :accepted
  end

end
