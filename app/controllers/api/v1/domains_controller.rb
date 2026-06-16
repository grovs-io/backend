class Api::V1::DomainsController < Api::V1::ProjectsBaseController
  include Api::V1::Concerns::CustomDomainOpsThrottling

  include DashboardAuthorization
  before_action :doorkeeper_authorize!, except: [:test]
  before_action :authorize_and_load_project, except: [:test]
  before_action :require_custom_domains_enabled,
                only: %i[custom_domain create_custom_domain delete_custom_domain
                         index_custom_domains create_custom_domain_v2 delete_custom_domain_v2
                         preflight_custom_domain]
  before_action :throttle_custom_domain_ops!,
                only: %i[create_custom_domain delete_custom_domain
                         create_custom_domain_v2 delete_custom_domain_v2]
  before_action :throttle_custom_domain_reads!, only: %i[preflight_custom_domain]

  def test
    skip_authorization
    request_domain = request.headers["X-Forwarded-Domain"] || request.domain
    request_subdomain = request.headers["X-Forwarded-Subdomain"] || request.subdomain
    request_path = request.headers["X-Forwarded-Path"]&.gsub(%r{^/}, "") || request.path[1..]

    render json: {
      request_domain: request_domain,
      request_subdomain: request_subdomain,
      request_path: request_path,
      original_host: request.headers["X-Original-Host"],
      inspect: request.inspect
    }
  end

  def current_project_domain
    domain = domain_for_current_project
    return unless domain

    render json: { domain: DomainSerializer.serialize(domain) }, status: :ok
  end

  def domain_defaults
    render json: {
      generic_title: Grovs::Links::DEFAULT_TITLE,
      generic_subtitle: Grovs::Links::DEFAULT_SUBTITLE,
      generic_image_url: Grovs::Links::SOCIAL_PREVIEW
    }, status: :ok
  end

  def check_and_link_domain
    domain = domain_for_current_project
    return unless domain

    is_available = DomainConfigurationService.domain_available?(domain_name: domain_param)
    unless is_available
      render json: { error: "This domain is not available" }, status: :unprocessable_entity
      return
    end

    render json: { error: "Not yet implemented" }, status: :not_implemented
  end

  def set_project_domain
    domain = domain_for_current_project
    return unless domain

    updated = DomainConfigurationService.update_domain(
      domain: domain,
      attrs: domain_params,
      generic_image: generic_image_param
    )

    render json: { domain: DomainSerializer.serialize(updated) }, status: :ok
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def domain_is_available
    available = DomainConfigurationService.subdomain_available?(
      subdomain: subdomain_param,
      is_test: @project.test?
    )

    render json: { available: available }, status: :ok
  end

  def set_google_tracking_id
    domain = domain_for_current_project
    return unless domain

    updated = DomainConfigurationService.update_domain(
      domain: domain,
      attrs: { google_tracking_id: google_tracking_id_param }
    )

    render json: { domain: DomainSerializer.serialize(updated) }, status: :ok
  end

  def custom_domain
    ch = @project.custom_hostnames.primary.first
    return render(json: { custom_domain: nil }, status: :ok) unless ch

    render json: { custom_domain: CustomHostnameSerializer.serialize(ch) }, status: :ok
  end

  def create_custom_domain
    result = CustomDomainProvisioningService.create(
      project: @project,
      hostname: custom_domain_param,
      purpose: Grovs::Hostnames::PURPOSE_PRIMARY
    )
    unless result.ok
      return render(json: { error: result.error }, status: result.status)
    end

    render json: { custom_domain: CustomHostnameSerializer.serialize(result.custom_hostname) }, status: :created
  end

  def delete_custom_domain
    ch = @project.custom_hostnames.primary.first
    return render(json: { error: "No custom domain configured" }, status: :not_found) unless ch

    if CustomDomainProvisioningService.destroy(ch)
      render json: { message: "Custom domain removed" }, status: :ok
    else
      render json: { message: "Custom domain disabled; cleanup will retry" }, status: :accepted
    end
  end

  def index_custom_domains
    # `order(:purpose)` alphabetizes (migration before primary), which is wrong product-wise.
    hostnames = @project.custom_hostnames.order(
      Arel.sql("CASE purpose WHEN 'primary' THEN 0 WHEN 'migration' THEN 1 ELSE 2 END")
    )
    render json: { custom_domains: hostnames.map { |ch| CustomHostnameSerializer.serialize(ch) } }, status: :ok
  end

  def create_custom_domain_v2
    # `params.require` would raise ParameterMissing, which Rails answers with HTML 400 —
    # breaking this API's `{ error: "..." }` JSON envelope.
    hostname = params[:hostname]
    purpose = params[:purpose]

    unless Grovs::Hostnames::PURPOSES.include?(purpose)
      return render(json: { error: "Invalid purpose" }, status: :unprocessable_entity)
    end

    result = CustomDomainProvisioningService.create(project: @project, hostname: hostname, purpose: purpose)
    unless result.ok
      return render(json: { error: result.error }, status: result.status)
    end

    render json: { custom_domain: CustomHostnameSerializer.serialize(result.custom_hostname) }, status: :created
  end

  def delete_custom_domain_v2
    purpose = params[:purpose]
    unless Grovs::Hostnames::PURPOSES.include?(purpose)
      return render(json: { error: "Invalid purpose" }, status: :unprocessable_entity)
    end

    ch = @project.custom_hostnames.where(purpose: purpose).first
    return render(json: { error: "No custom domain configured" }, status: :not_found) unless ch

    if CustomDomainProvisioningService.destroy(ch)
      render json: { message: "Custom domain removed" }, status: :ok
    else
      render json: { message: "Custom domain disabled; cleanup will retry" }, status: :accepted
    end
  end

  # `checked_at` reflects when the DNS lookup ran (not the request), so the FE can detect cached responses.
  PREFLIGHT_CACHE_TTL = 30.seconds

  def preflight_custom_domain
    # Normalization must match MigrationsController#create / MigrationSource#normalize_old_host,
    # else "links.acme.com:443" preflights as no-match but the eventual POST succeeds.
    hostname = params[:hostname].to_s.strip.downcase.chomp(".").sub(/:\d+\z/, "")
    return render(json: { error: "Hostname is required" }, status: :unprocessable_entity) if hostname.blank?
    return render(json: { error: "Hostname must be valid ASCII" }, status: :unprocessable_entity) unless hostname.ascii_only?
    unless hostname.include?(".")
      return render(json: { error: "Hostname must look like a domain (e.g. links.acme.com)" },
                    status: :unprocessable_entity)
    end

    expected = CloudflareCustomHostnameService.cname_target
    cache_key = "custom_domain:preflight:#{@project.id}:#{hostname}"
    actual, dns_error, checked_at = Rails.cache.fetch(cache_key, expires_in: PREFLIGHT_CACHE_TTL) do
      lookup_actual, lookup_error = DnsCnameLookupService.lookup(hostname)
      [lookup_actual, lookup_error, Time.current.utc.iso8601]
    end
    matches = actual.present? && expected.present? &&
              actual.downcase.chomp(".") == expected.downcase.chomp(".")

    body = {
      hostname:       hostname,
      cname_expected: expected,
      cname_actual:   actual,
      cname_matches:  matches,
      checked_at:     checked_at
    }
    body[:dns_error] = dns_error if dns_error.present?
    render json: body, status: :ok
  end

  private

  def require_custom_domains_enabled
    return if Grovs.custom_domains_enabled?

    render json: { error: "Custom domains are not enabled" }, status: :not_found
  end

  def custom_domain_param
    params.require(:hostname)
  end

  def generic_image_param
    params.permit(:generic_image)[:generic_image]
  end

  def subdomain_param
    params.require(:subdomain)
  end

  def domain_params
    params.permit(:generic_title, :generic_subtitle, :subdomain, :generic_image_url)
  end

  def domain_param
    params.require(:domain)
  end

  def google_tracking_id_param
    params.permit(:google_tracking_id)[:google_tracking_id]
  end
end
