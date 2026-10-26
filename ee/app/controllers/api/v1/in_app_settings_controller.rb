class Api::V1::InAppSettingsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  wrap_parameters false
  FIELDS = %w[enabled session_cap day_cap control_group push_daily_cap].freeze

  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project
  before_action :require_in_app

  def show = render_setting(InAppSetting.for(@project))

  def update
    setting = save_setting
    return render json: { error: setting.errors.full_messages.join(", ") }, status: :unprocessable_entity if setting.errors.any?

    audit!("in_app_settings.updated", instance_id: @project.instance_id, target: audit_target(@project),
                                      changes: { "after" => setting.slice(*FIELDS) })
    render_setting(setting)
  end

  rescue_from ActiveModel::RangeError, ActiveRecord::NotNullViolation do
    render json: { error: "A value is missing or out of range" }, status: :unprocessable_entity
  end

  private

  # Two first saves at once: the second finds the row the first made, and saves into that.
  def save_setting(again: true)
    setting = InAppSetting.for(@project)
    FIELDS.each { |k| setting.public_send("#{k}=", params[k]) if params.key?(k) }
    setting.save
    setting
  rescue ActiveRecord::RecordNotUnique
    raise unless again

    save_setting(again: false)
  end

  def render_setting(setting)
    render json: { in_app_settings: setting.slice(*FIELDS) }, status: :ok
  end

  def require_in_app
    return if @project.instance.in_app_enabled?

    render json: { error: "In-app messages are not enabled" }, status: :not_found
  end
end
