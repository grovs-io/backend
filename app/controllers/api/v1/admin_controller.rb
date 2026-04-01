class Api::V1::AdminController < Api::V1::ProjectsBaseController
  before_action :authenticate_request

  def create_enterprise_subscription
    subscription = EnterpriseSubscriptionService.create(
      instance_id: params[:instance_id],
      start_date: params[:start_date],
      end_date: params[:end_date],
      total_maus: params[:total_maus],
      active: params[:active]
    )

    render json: { message: "Enterprise Subscription created successfully", subscription: subscription }, status: :created
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotFound => e
    render json: { error: e.message }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Failed to create subscription", details: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def migrate_firebase_links
    file = params[:file]

    unless file && file.content_type == "text/csv"
      render json: { error: "Please upload a valid CSV file." }, status: :unprocessable_entity
      return
    end

    project = Project.find_by(id: params[:project_id])
    unless project
      render json: { error: "Project not found" }, status: :not_found
      return
    end

    result = FirebaseMigrationService.new(
      project: project,
      deeplink_prefix: params[:deeplink_prefix],
      short_link_prefix: params[:short_link_prefix]
    ).import_csv(file.path)
    render json: result, status: :ok
  rescue StandardError => e
    render json: { error: "Failed to parse CSV: #{e.message}" }, status: :unprocessable_entity
  end

  def flush_events
    days = params[:aggregate_days] || 1
    result = EventFlushService.flush(aggregate_days: days)

    render json: {
      message: "Events flushed and metrics aggregated",
      processed: result[:processed],
      discarded: result[:discarded],
      dates_aggregated: result[:dates_aggregated]
    }, status: :ok
  rescue StandardError => e
    render json: { error: e.message }, status: :internal_server_error
  end

  def update_enterprise_subscription
    subscription = EnterpriseSubscriptionService.update(
      id: params[:id],
      attrs: params.permit(:active, :start_date, :end_date, :total_maus)
    )

    render json: { message: "Enterprise Subscription updated successfully", subscription: subscription }, status: :ok
  rescue ActiveRecord::RecordNotFound => e
    render json: { error: e.message }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Failed to update subscription", details: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def authenticate_request
    x_auth = request.headers["X-AUTH"]

    if ENV["ADMIN_API_KEY"].blank? || !ActiveSupport::SecurityUtils.secure_compare(x_auth.to_s, ENV["ADMIN_API_KEY"])
      render json: { error: "Invalid credentials" }, status: :forbidden
      return false
    end

    true
  end
end
