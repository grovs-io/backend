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
    provider_hosted = ActiveModel::Type::Boolean.new.cast(params[:provider_hosted]) == true
    raw_extra_hosts = params[:extra_hosts]

    unless hostname.present? && provider.present? && raw_credentials.present?
      return render(json: { error: "hostname, provider, and credentials are required" },
                    status: :unprocessable_entity)
    end

    return if create_request_blocked?(provider_hosted, raw_extra_hosts)

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
    required = CREDENTIALS_ALLOWED_KEYS[provider] || []
    missing  = required - credentials.keys
    unless missing.empty?
      return render(json: { error: "Credentials missing keys: #{missing.join(', ')}" },
                    status: :unprocessable_entity)
    end

    return if credentials_probe_blocks?(provider, hostname, credentials)

    if provider_hosted
      return create_provider_hosted_source(hostname, provider, credentials, raw_extra_hosts)
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
        # NOT build_migration_source: has_one replacement destroys instead of raising on a race.
        source = MigrationSource.new(
          project: @project, provider: provider, old_host: hostname, credentials: credentials
        )
        save_migration_source!(source)
      end

      render json: {
        custom_domain: CustomHostnameSerializer.serialize(custom_hostname),
        migration_source: MigrationSourceSerializer.serialize(source)
      }.merge(deployment_fields), status: :created
    rescue ActiveRecord::RecordInvalid => e
      # Release via the provisioning service so Cloudflare is freed too, else the slot wedges.
      destroyed = CustomDomainProvisioningService.destroy(custom_hostname)
      if destroyed == false
        # 502 (not 422): partial-cleanup failure, swept later by reap_orphaned_suspended.
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
      render json: { error: DUPLICATE_SOURCE_ERROR }, status: :conflict
    rescue StandardError => e
      # Destroy releases CF + DB, then re-raise the original; the lifecycle job is the backstop.
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

  # Only a definitive credentials_invalid blocks onboarding; transient upstream errors don't.
  def credentials_probe_blocks?(provider, hostname, credentials)
    probe = MigrationProviderClient.for(
      MigrationSource.new(provider: provider, old_host: hostname, credentials: credentials)
    ).probe
    return false unless probe.probe_outcome == MigrationLookupResult::PROBE_INVALID

    Grovs::Metrics.increment("migration.onboarding.credentials_invalid",
                             tags: { provider: provider })
    render json: { error: credentials_invalid_message(provider, probe.http_status) },
           status: :unprocessable_entity
    true
  end

  def create_request_blocked?(provider_hosted, extra_hosts)
    error =
      if provider_hosted && !Grovs.self_hosted?
        "provider_hosted migration sources are only available on self-hosted deployments"
      elsif extra_hosts.present? && !extra_hosts.is_a?(Array)
        "extra_hosts must be an array of hostnames"
      elsif extra_hosts.present? && !provider_hosted
        "extra_hosts requires provider_hosted: true"
      end
    if error
      render json: { error: error }, status: :unprocessable_entity
      return true
    end

    # Both modes: has_one replacement would otherwise silently destroy an existing source (201!).
    if @project.migration_source
      render json: { error: DUPLICATE_SOURCE_ERROR }, status: :conflict
      return true
    end

    false
  end

  # No CustomHostname/Cloudflare: the domain stays hosted by the provider (e.g. xyz.app.link).
  def create_provider_hosted_source(hostname, provider, credentials, extra_hosts)
    # NOT build_migration_source: has_one replacement silently destroys an existing source.
    source = MigrationSource.new(
      project: @project, provider: provider, old_host: hostname, credentials: credentials,
      provider_hosted: true, extra_hosts: Array(extra_hosts).map(&:to_s)
    )
    ActiveRecord::Base.transaction { save_migration_source!(source) }
    render json: { migration_source: MigrationSourceSerializer.serialize(source) }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    render json: { error: DUPLICATE_SOURCE_ERROR }, status: :conflict
  end

  def save_migration_source!(source)
    source.save!
    audit!("migration_source.created", instance_id: @project.instance_id,
           target: audit_target(source).merge("provider" => source.provider, "hostname" => source.old_host))
  end

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

  DUPLICATE_SOURCE_ERROR = "Migration source already configured for this project".freeze

  # Slice to the provider's keys so customers can't stuff arbitrary KVs into the encrypted blob.
  # Non-Hash inputs return {} so the downstream model validator yields a clean 422 instead of a 500.
  def slice_credentials(creds, provider)
    return {} unless creds.is_a?(Hash) || creds.is_a?(ActionController::Parameters)
    hash = creds.respond_to?(:to_unsafe_h) ? creds.to_unsafe_h.stringify_keys : creds.to_h.stringify_keys
    allowed = CREDENTIALS_ALLOWED_KEYS[provider] || []
    hash.slice(*allowed)
  end
end
