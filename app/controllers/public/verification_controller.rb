
class Public::VerificationController < ApplicationController

  # Generates the well know hosts iOS file
  def generate_ios_file
    domain = current_domain
    unless domain
      render json: {error: "Domain not found"}, status: :not_found
      return
    end

    instance = domain.project.instance
    project = domain.project
    ios_application = instance.ios_application
    redirect_config = project.redirect_config

    unless ios_application
      render json: {error: "Application not found"}, status: :not_found
      return
    end

    ios_configuration = ios_application.configuration
    unless ios_configuration
      render json: {error: "Configuration not set"}, status: :not_found
      return
    end

    # tablet_config = redirect_config.ios_phone_redirect
    phone_config = redirect_config.ios_phone_redirect
    if !phone_config || !phone_config.enabled
      render json: {error: "Configuration not enabled"}, status: :not_found
      return
    end

    app_id = "#{ios_configuration.app_prefix}.#{ios_configuration.bundle_id}"

    file = IOS_VERIFICATION_FILE
    file[:applinks][:details][0][:appID] = app_id

    render json: file, status: :ok
  end

  def generate_android_file
    domain = current_domain
    unless domain
      render json: {error: "Domain not found"}, status: :not_found
      return
    end

    instance = domain.project.instance
    android_application = instance.android_application
    project = domain.project
    redirect_config = project.redirect_config

    unless android_application
      render json: {error: "Application not found"}, status: :not_found
      return
    end

    android_configuration = android_application.configuration
    unless android_configuration
      render json: {error: "Configuration not set"}, status: :not_found
      return
    end

    phone_config = redirect_config.android_phone_redirect
    if !phone_config || !phone_config.enabled
      render json: {error: "Configuration not enabled"}, status: :not_found
      return
    end

    file = ANDROID_VERIFICATION_FILE
    file[:target][:package_name] = android_configuration.identifier
    file[:target][:sha256_cert_fingerprints] = android_configuration.sha256s

    render json: [file], status: :ok
  end

  private

  def current_domain
    Domain.find_by(subdomain: request.subdomain, domain: request.domain)
  end

end