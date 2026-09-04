class Api::V1::AdminController < Api::V1::ProjectsBaseController
  before_action :authenticate_request

  def create_enterprise_subscription
    subscription = nil
    ActiveRecord::Base.transaction do
      subscription = EnterpriseSubscriptionService.create(
        instance_id: params[:instance_id],
        start_date: params[:start_date],
        end_date: params[:end_date],
        total_maus: params[:total_maus],
        active: params[:active]
      )
      audit!("enterprise_subscription.created", instance_id: subscription.instance_id, target: audit_target(subscription), changes: audit_diff(subscription))
    end

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

    begin
      result = FirebaseMigrationService.new(
        project: project,
        deeplink_prefix: params[:deeplink_prefix],
        short_link_prefix: params[:short_link_prefix]
      ).import_csv(file.path)
    rescue StandardError => e
      return render(json: { error: "Failed to parse CSV: #{e.message}" }, status: :unprocessable_entity)
    end

    audit!("links.firebase_imported", instance_id: project.instance_id, target: audit_target(project),
           changes: { "after" => result.slice(:created_count, :skipped_count) })
    render json: result, status: :ok
  end

  def flush_events
    days = params[:aggregate_days] || 1
    result = EventFlushService.flush(aggregate_days: days)
    # Global, not tenant-scoped: no AuditEvent row, operator log only.
    Rails.logger.warn(message: "audit.events_flushed", actor: "admin_key", ip: Current.ip, aggregate_days: days)

    render json: {
      message: "Events flushed and metrics aggregated",
      processed: result[:processed],
      discarded: result[:discarded],
      dates_aggregated: result[:dates_aggregated]
    }, status: :ok
  rescue StandardError => e
    render json: { error: e.message }, status: :internal_server_error
  end

  # Super-admin setter for an instance's retention windows. Partial update;
  # validation lives in the Instance model + DB constraint.
  def update_instance_retention
    instance = Instance.find_by(id: params[:instance_id])
    return render(json: { error: "Instance not found" }, status: :not_found) unless instance

    attrs = {}
    attrs[:cold_storage_days] = Integer(params[:cold_storage_days]) if params[:cold_storage_days].present?
    attrs[:delete_days] = Integer(params[:delete_days]) if params[:delete_days].present?
    instance.assign_attributes(attrs)

    saved = ActiveRecord::Base.transaction do
      next false unless instance.save

      audit!("instance.retention_changed", instance_id: instance.id,
             target: audit_target(instance), changes: audit_diff(instance))
      true
    end

    if saved
      render json: { cold_storage_days: instance.cold_storage_days, delete_days: instance.delete_days }, status: :ok
    else
      render json: { error: instance.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  rescue ArgumentError
    render json: { error: "cold_storage_days and delete_days must be integers" }, status: :unprocessable_entity
  end

  def update_enterprise_subscription
    # Deactivation removes the entitlement the gate checks, so decide it from the pre-update state.
    entitled_before = EnterpriseSubscription.find_by(id: params[:id])&.instance&.audit_log_enabled?
    subscription = nil
    ActiveRecord::Base.transaction do
      subscription = EnterpriseSubscriptionService.update(
        id: params[:id],
        attrs: params.permit(:active, :start_date, :end_date, :total_maus)
      )
      Audit.record(instance_id: subscription.instance_id, action: "enterprise_subscription.updated", actor: audit_actor,
                        target: audit_target(subscription), changes: audit_diff(subscription),
                        entitled: entitled_before || subscription.instance.audit_log_enabled?)
    end

    render json: { message: "Enterprise Subscription updated successfully", subscription: subscription }, status: :ok
  rescue ActiveRecord::RecordNotFound => e
    render json: { error: e.message }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Failed to update subscription", details: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  # Bypasses subscription entitlement; source: "enterprise" so the lifecycle job never tears it down.
  def create_custom_domain
    return render(json: { error: "Custom domains are not enabled" }, status: :not_found) unless Grovs.custom_domains_enabled?

    project = Project.find_by(id: params[:project_id])
    return render(json: { error: "Project not found" }, status: :not_found) unless project

    purpose = params[:purpose].presence || Grovs::Hostnames::PURPOSE_PRIMARY
    unless Grovs::Hostnames::PURPOSES.include?(purpose)
      return render(json: { error: "Invalid purpose" }, status: :unprocessable_entity)
    end

    result = CustomDomainProvisioningService.create(project: project, hostname: params.require(:hostname), as_enterprise: true, purpose: purpose)
    unless result.ok
      return render(json: { error: result.error }, status: result.status)
    end

    audit!("custom_domain.created", instance_id: project.instance_id,
           target: audit_target(result.custom_hostname).merge("hostname" => result.custom_hostname.hostname, "purpose" => purpose))

    render json: { custom_domain: CustomHostnameSerializer.serialize(result.custom_hostname) }, status: :created
  end

  private

  def authenticate_request
    x_auth = request.headers["X-AUTH"]

    if ENV["ADMIN_API_KEY"].blank? || !ActiveSupport::SecurityUtils.secure_compare(x_auth.to_s, ENV["ADMIN_API_KEY"])
      render json: { error: "Invalid credentials" }, status: :forbidden
      return false
    end

    Current.actor = AuditActor.admin_key
    true
  end
end
