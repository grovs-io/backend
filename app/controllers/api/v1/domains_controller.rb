class Api::V1::DomainsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  before_action :doorkeeper_authorize!, except: [:test]
  before_action :authorize_and_load_project, except: [:test]

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

  private

  # Params

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
