class Api::V1::ConfigurationsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  before_action :doorkeeper_authorize!
  before_action :load_instance
  rescue_from ActiveRecord::RecordInvalid, with: :render_validation_error
  rescue_from ArgumentError, with: :render_validation_error

  def current_project_configurations
    applications = @instance.applications.includes(
      :ios_configuration, :android_configuration, :desktop_configuration, :web_configuration
    )
    render json: { configurations: ApplicationSerializer.serialize(applications) }, status: :ok
  end

  def set_ios_configuration
    app = ActiveRecord::Base.transaction do
      a = PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::IOS, enabled: enabled_param, config_params: ios_config_params
      )
      audit_config!("ios_configuration.updated", ios_config_params.merge(enabled: enabled_param))
      a
    end
    render json: {config: ApplicationSerializer.serialize(app)}, status: :ok
  end

  def set_ios_push_configuration
    app = ActiveRecord::Base.transaction do
      a = PlatformConfigurationService.set_ios_push_configuration(
        instance: @instance, certificate_params: ios_push_certificate_params
      )
      audit_config!("ios_push_configuration.updated", ios_push_certificate_params)
      a
    end
    render json: {config: ApplicationSerializer.serialize(app)}, status: :ok
  end

  def set_android_configuration
    app = ActiveRecord::Base.transaction do
      a = PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::ANDROID, enabled: enabled_param, config_params: android_config_params
      )
      audit_config!("android_configuration.updated", android_config_params.merge(enabled: enabled_param))
      a
    end
    render json: {config: ApplicationSerializer.serialize(app)}, status: :ok
  end

  def set_android_push_configuration
    app = ActiveRecord::Base.transaction do
      a = PlatformConfigurationService.set_android_push_configuration(
        instance: @instance, certificate_params: android_push_certificate_params
      )
      audit_config!("android_push_configuration.updated", android_push_certificate_params)
      a
    end
    render json: {config: ApplicationSerializer.serialize(app)}, status: :ok
  end

  def set_android_api_access_key
    app = ActiveRecord::Base.transaction do
      a = PlatformConfigurationService.set_android_api_access_key(
        instance: @instance, key_params: android_server_access_key_params
      )
      audit_config!("android_api_access_key.updated", { file: "[uploaded]" })
      a
    end
    render json: {config: ApplicationSerializer.serialize(app)}, status: :ok
  end

  def set_ios_api_access_key
    app = ActiveRecord::Base.transaction do
      a = PlatformConfigurationService.set_ios_api_access_key(
        instance: @instance, key_params: ios_server_access_key_params
      )
      audit_config!("ios_api_access_key.updated", ios_server_access_key_params.except(:file).merge(file: "[uploaded]"))
      a
    end
    render json: {config: ApplicationSerializer.serialize(app)}, status: :ok
  end

  def set_desktop_configuration
    app = ActiveRecord::Base.transaction do
      a = PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::DESKTOP, enabled: enabled_param, config_params: desktop_config_params
      )
      audit_config!("desktop_configuration.updated", desktop_config_params.merge(enabled: enabled_param))
      a
    end
    render json: {config: ApplicationSerializer.serialize(app)}, status: :ok
  end

  def google_configuration_script
    script = PlatformConfigurationService.google_configuration_script(instance: @instance)

    send_data script,
              filename: "grovs_android_gcloud_setup.sh",
              type: "application/x-sh",
              disposition: "attachment"
  end

  def set_web_configuration
    app = ActiveRecord::Base.transaction do
      a = PlatformConfigurationService.set_web_configuration(
        instance: @instance, enabled: enabled_param, config_params: web_config_params
      )
      audit_config!("web_configuration.updated", web_config_params.merge(enabled: enabled_param))
      a
    end
    render json: {config: ApplicationSerializer.serialize(app)}, status: :ok
  end

  def remove_ios_configuration
    ActiveRecord::Base.transaction do
      PlatformConfigurationService.remove_configuration(instance: @instance, platform: Grovs::Platforms::IOS)
      @instance.setup_progress_steps.where(category: "ios_setup").delete_all
      audit_config!("ios_configuration.removed", {})
    end
    render json: { config: nil }, status: :ok
  end

  def remove_android_configuration
    ActiveRecord::Base.transaction do
      PlatformConfigurationService.remove_configuration(instance: @instance, platform: Grovs::Platforms::ANDROID)
      @instance.setup_progress_steps.where(category: "android_setup").delete_all
      audit_config!("android_configuration.removed", {})
    end
    render json: { config: nil }, status: :ok
  end

  def remove_desktop_configuration
    ActiveRecord::Base.transaction do
      PlatformConfigurationService.remove_configuration(instance: @instance, platform: Grovs::Platforms::DESKTOP)
      audit_config!("desktop_configuration.removed", {})
    end
    render json: { config: nil }, status: :ok
  end

  def remove_web_configuration
    ActiveRecord::Base.transaction do
      PlatformConfigurationService.remove_web_configuration(instance: @instance)
      @instance.setup_progress_steps.where(category: "web_setup").delete_all
      audit_config!("web_configuration.removed", {})
    end
    render json: { config: nil }, status: :ok
  end

  private

  def audit_config!(action, params_hash)
    audit!(action, instance_id: @instance.id, target: audit_target(@instance), changes: { "after" => params_hash.to_h })
  end

  # Params

  def enabled_param
    params.require(:enabled)
  end

  def ios_config_params
    params.permit(:bundle_id, :app_prefix, :tablet_enabled)
  end

  def ios_push_certificate_params
    params.permit(:push_certificate_password, :push_certificate)
  end

  def android_push_certificate_params
    params.permit(:firebase_project_id, :push_certificate)
  end

  def android_server_access_key_params
    params.permit(:file)
  end

  def ios_server_access_key_params
    params.permit(:file, :key_id, :issuer_id)
  end

  def android_config_params
    params.permit(:identifier, { sha256s: [] }, :tablet_enabled)
  end

  def android_sha256_params
    JSON.parse(params.require(:sha256s))

  end

  def desktop_config_params
    params.permit(:generated_page, :fallback_url, :mac_uri, :windows_uri, :mac_enabled, :windows_enabled)
  end

  def web_config_params
    params.permit(domains: [])
  end

  def render_validation_error(exception)
    render json: { error: exception.message }, status: :unprocessable_entity
  end

end
