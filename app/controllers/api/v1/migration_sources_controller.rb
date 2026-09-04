class Api::V1::MigrationSourcesController < Api::V1::ProjectsBaseController
  # wrap_parameters nests the body under :migration_source, which breaks the
  # additionalProperties: false JSON Schema contract.
  wrap_parameters false

  include DashboardAuthorization
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project
  before_action :require_migrations_enabled
  before_action :require_admin_for_project
  before_action :load_source, only: %i[update destroy test]

  def show
    source = @project.migration_source
    payload = source ? MigrationSourceSerializer.serialize(source) : nil
    render json: { migration_source: payload }, status: :ok
  end

  def update
    ActiveRecord::Base.transaction do
      @source.update!(update_params)
      audit!("migration_source.updated", instance_id: @project.instance_id, target: migration_source_target(@source), changes: audit_diff(@source))
    end
    render json: { migration_source: MigrationSourceSerializer.serialize(@source) }, status: :ok
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end

  def destroy
    target = migration_source_target(@source)
    ActiveRecord::Base.transaction do
      @source.destroy!
      audit!("migration_source.deleted", instance_id: @project.instance_id, target: target)
    end
    render json: { message: "Migration source removed" }, status: :ok
  end

  def test
    # Per-source (not per-IP like Rack::Attack), so an admin behind multiple IPs
    # can't burn the customer's upstream quota.
    unless FirstHitMigration.upstream_rate_limit_ok?(@source)
      Grovs::Metrics.increment("migration.probe.rate_limited", tags: { provider: @source.provider })
      render json: { error: "Too many probes for this source — try again in a minute" },
             status: :too_many_requests
      return
    end

    result = MigrationProviderClient.for(@source).probe
    outcome = result.probe_outcome
    if outcome == MigrationLookupResult::PROBE_OK
      @source.record_success!
    elsif outcome == MigrationLookupResult::PROBE_UNEXPECTED
      Rails.logger.warn(message: "migration_probe_unexpected_success",
                                  source_id: @source.id,
                                  hint: "sentinel slug returned 200 — investigate")
    end
    render json: { outcome: outcome, http_status: result.http_status }, status: :ok
  end

  private

  def migration_source_target(source)
    audit_target(source).merge("provider" => source.provider, "hostname" => source.old_host)
  end

  def load_source
    @source = @project.migration_source
    return if @source
    render json: { error: "Migration source not configured for this project" }, status: :not_found
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

  def update_params
    raw = params.permit(:enabled, credentials: {}, extra_hosts: [])
    if raw[:credentials].present? && @source
      raw[:credentials] = slice_credentials(raw[:credentials], @source.provider)
    end
    raw
  end

  # Slice to the provider's keys so customers can't stuff arbitrary KVs into the encrypted blob.
  # Non-Hash inputs return {} so the downstream model validator yields a clean 422 instead of a 500.
  def slice_credentials(creds, provider)
    return {} unless creds.is_a?(Hash) || creds.is_a?(ActionController::Parameters)
    hash = creds.respond_to?(:to_unsafe_h) ? creds.to_unsafe_h.stringify_keys : creds.to_h.stringify_keys
    allowed = CREDENTIALS_ALLOWED_KEYS[provider] || []
    hash.slice(*allowed)
  end
end
