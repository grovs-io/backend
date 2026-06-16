class Api::V1::ExportController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project, only: [:export_link_data]
  before_action :load_instance, only: [:export_usage_data]

  def export_link_data
    campaign_id = validated_campaign_id
    return if performed?

    safe_params = {
      "active" => ActiveModel::Type::Boolean.new.cast(params[:active]),
      "sdk" => ActiveModel::Type::Boolean.new.cast(params[:sdk]),
      "start_date" => params[:start_date].presence,
      "end_date" => params[:end_date].presence,
      "campaign_id" => campaign_id
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

  private

  # Returns the campaign id as an integer, or nil when the param is absent.
  # Renders 400/404 (check performed?) for malformed or foreign campaign ids.
  def validated_campaign_id
    raw = params.permit(:campaign_id)[:campaign_id].presence
    return nil unless raw

    campaign_id = Integer(raw, exception: false)
    if campaign_id.nil?
      render json: { error: "campaign_id must be an integer" }, status: :bad_request
      return
    end

    unless @project.campaigns.exists?(id: campaign_id)
      render json: { error: "Campaign not found" }, status: :not_found
      return
    end

    campaign_id
  end
end
