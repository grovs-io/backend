class Api::V1::ExportController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  include Api::V1::Concerns::AnalyticsRetentionGate
  # wrap_parameters nests JSON bodies under :export, breaking the strict request contract.
  wrap_parameters false
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project, only: [:export_link_data]
  before_action :load_instance, only: [:export_usage_data]
  before_action :validate_campaign_id!, only: [:export_link_data]
  # export_usage_data reads CH but is instance-scoped MAU/billing, so it stays ungated.
  before_action :enforce_ch_retention_window!, only: [:export_link_data]

  def export_link_data
    campaign_id = campaign_id_param
    return if campaign_id && !campaign_owned_by_project?(campaign_id)

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
    audit!("export.link_data", instance_id: @project.instance_id, target: audit_target(@project), changes: { "after" => safe_params })

    render json: { message: "Export job has been queued. You will be notified when it's ready." }, status: :accepted
  end

  # DEPRECATED (2026-07-25): remove route+job+ActiveUsersReport after zero-traffic check.
  def export_usage_data
    Grovs::Metrics.increment("deprecated_endpoint.hit", tags: { endpoint: "export/usage_data" })
    safe_params = {
      "start_date" => params[:start_date].presence,
      "end_date" => params[:end_date].presence,
    }.compact

    ExportActivityDataJob.perform_async(
      @instance.id,
      safe_params,
      current_user.id
    )
    audit!("export.usage_data", instance_id: @instance.id, target: audit_target(@instance), changes: { "after" => safe_params })

    render json: { message: "Export job has been queued. You will be notified when it's ready." }, status: :accepted
  end

  private

  def campaign_owned_by_project?(campaign_id)
    return true if @project.campaigns.exists?(id: campaign_id)
    render json: { error: "Campaign not found" }, status: :not_found
    false
  end
end
