class Api::V1::MigrationsController < Api::V1::ProjectsBaseController
  # wrap_parameters nests the body under :migration, which breaks the
  # additionalProperties: false JSON Schema contract.
  wrap_parameters false

  include Api::V1::Concerns::CustomDomainOpsThrottling
  include DashboardAuthorization

  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project
  before_action :require_migrations_enabled
  before_action :require_admin_for_project
  before_action :throttle_custom_domain_ops!

  def create
    hostname = params[:hostname].to_s.strip.downcase.chomp(".").sub(/:\d+\z/, "")
    provider = params[:provider]
    raw_credentials = params[:credentials]

    unless hostname.present? && provider.present? && raw_credentials.present?
      return render(json: { error: "hostname, provider, and credentials are required" },
                    status: :unprocessable_entity)
    end

    unless Grovs::Migrations::MVP_PROVIDERS.include?(provider)
      return render(json: { error: "Provider is not included in the list" },
                    status: :unprocessable_entity)
    end

    # Skip a Cloudflare round-trip on a request already destined to 409.
    existing = CustomHostname.redis_find_by(:hostname, hostname)
    if existing && existing.project_id != @project.id
      return render(json: { error: "hostname is attached as a custom domain on a different project" },
                    status: :conflict)
    end

    credentials = slice_credentials(raw_credentials, provider)

    # Pre-validate before spending a ~15s Cloudflare round-trip + compensating delete.
    # MigrationSource#credentials_shape_for_provider re-validates on save with the same wording.
    required = CREDENTIALS_ALLOWED_KEYS[provider] || []
    missing  = required - credentials.keys
    unless missing.empty?
      return render(json: { error: "Credentials missing keys: #{missing.join(', ')}" },
                    status: :unprocessable_entity)
    end

    # Probe upstream with the supplied credentials BEFORE the ~15s Cloudflare round-trip.
    # A definitive credentials_invalid (bad key / no OneLink API entitlement) blocks
    # onboarding with a clear error instead of letting every future click silently fall
    # back to project defaults. Transient/unreachable upstream errors do NOT block — the
    # runtime resolver degrades gracefully and creds may simply be momentarily unreachable.
    probe = MigrationProviderClient.for(
      MigrationSource.new(provider: provider, old_host: hostname, credentials: credentials)
    ).probe
    if probe.probe_outcome == MigrationLookupResult::PROBE_INVALID
      Grovs::Metrics.increment("migration.onboarding.credentials_invalid",
                               tags: { provider: provider })
      return render(json: { error: credentials_invalid_message(provider, probe.http_status) },
                    status: :unprocessable_entity)
    end

    result = CustomDomainProvisioningService.create(
      project: @project, hostname: hostname,
      purpose: Grovs::Hostnames::PURPOSE_MIGRATION
    )
    unless result.ok
      return render(json: { error: result.error }, status: result.status)
    end

    custom_hostname = result.custom_hostname

    begin
      source = nil
      ActiveRecord::Base.transaction do
        source = @project.build_migration_source(
          provider: provider, old_host: hostname, credentials: credentials
        )
        source.save!
      end

      render json: {
        custom_domain: CustomHostnameSerializer.serialize(custom_hostname),
        migration_source: MigrationSourceSerializer.serialize(source)
      }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      # Use the provisioning service (not custom_hostname.destroy!) so Cloudflare is released too;
      # otherwise the project's migration slot stays wedged.
      destroyed = CustomDomainProvisioningService.destroy(custom_hostname)
      if destroyed == false
        # Suspended-but-not-deleted rows are swept by RefreshCustomHostnameStatusJob#reap_orphaned_suspended.
        # 502 (not 422) signals partial-cleanup failure vs. bad input.
        Rails.logger.warn(message: "migrations_create_cleanup_failed",
                          project_id: @project.id,
                          custom_hostname_id: custom_hostname.id,
                          hostname: custom_hostname.hostname)
        return render(json: {
          error: "Cloudflare cleanup failed after a partial setup; the migration slot " \
                 "will be released automatically within a few minutes. If this persists, contact support."
        }, status: :bad_gateway)
      end

      render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
    rescue ActiveRecord::RecordNotUnique
      CustomDomainProvisioningService.destroy(custom_hostname)
      render json: { error: "Migration source already configured for this project" }, status: :conflict
    rescue StandardError => e
      # PG disconnect, deadlock, Redis cache invalidation failure, encryption error —
      # anything not already handled above. Without this rescue the CH is created but
      # orphaned until the lifecycle job's stuck-provisioning recovery reaps it.
      # Destroy releases CF + DB; re-raise so Rack still logs the 500 and the alerting
      # path fires. Errors during destroy are swallowed — the lifecycle job is the
      # backstop, and we'd rather propagate the original cause than a secondary error.
      begin
        CustomDomainProvisioningService.destroy(custom_hostname)
      rescue StandardError => cleanup_error
        Rails.logger.error(message: "migrations_create_cleanup_after_error_failed",
                           project_id: @project.id,
                           custom_hostname_id: custom_hostname&.id,
                           original_error: e.class.name,
                           cleanup_error: cleanup_error.class.name)
      end
      raise
    end
  end

  private

  # AppsFlyer 401 is most often a missing OneLink API entitlement (the OneLink token type
  # only exists on paid plans) — call that out so the customer fixes it on AppsFlyer's side.
  def credentials_invalid_message(provider, http_status)
    case provider
    when Grovs::Migrations::PROVIDER_APPSFLYER
      "Credentials rejected by AppsFlyer (HTTP #{http_status}). Verify the onelink_id, and " \
        "ensure your AppsFlyer plan includes OneLink API access — it requires a OneLink-type " \
        "token from the Security Center, which is only available on plans with that entitlement."
    else
      "Credentials rejected by #{provider} (HTTP #{http_status}). Double-check the values and resave."
    end
  end

  def require_migrations_enabled
    return if Grovs.migrations_enabled?
    render json: { error: "Migrations are not enabled in this deployment" },
           status: :service_unavailable
  end

  def require_admin_for_project
    role = InstanceRole.find_by(instance_id: @project.instance_id, user_id: current_user.id)
    return if role && role.role == Grovs::Roles::ADMIN
    render json: { error: "Forbidden" }, status: :forbidden
  end

  CREDENTIALS_ALLOWED_KEYS = {
    Grovs::Migrations::PROVIDER_BRANCH    => %w[branch_key],
    Grovs::Migrations::PROVIDER_APPSFLYER => %w[onelink_id api_token]
  }.freeze

  # Slice to the provider's keys so customers can't stuff arbitrary KVs into the encrypted blob.
  # Non-Hash inputs return {} so the downstream model validator yields a clean 422 instead of a 500.
  def slice_credentials(creds, provider)
    return {} unless creds.is_a?(Hash) || creds.is_a?(ActionController::Parameters)
    hash = creds.respond_to?(:to_unsafe_h) ? creds.to_unsafe_h.stringify_keys : creds.to_h.stringify_keys
    allowed = CREDENTIALS_ALLOWED_KEYS[provider] || []
    hash.slice(*allowed)
  end
end
