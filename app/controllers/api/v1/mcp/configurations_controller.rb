class Api::V1::Mcp::ConfigurationsController < Api::V1::Mcp::BaseController
  before_action :load_mcp_project, only: [:setup_redirects]
  before_action :load_mcp_instance, only: [:setup_sdk]

  # PUT /api/v1/mcp/redirects
  def setup_redirects
    redirect_config = @project.redirect_config || RedirectConfig.new(project: @project)

    if params[:default_fallback].present?
      redirect_config.default_fallback = params[:default_fallback]
      redirect_config.show_preview_ios = params.fetch(:show_preview_ios, redirect_config.show_preview_ios)
      redirect_config.show_preview_android = params.fetch(:show_preview_android, redirect_config.show_preview_android)
    end

    redirect_config.save!

    if params[:platforms].present?
      unsupported = params[:platforms].keys.find { |p| !permitted_platform?(p) }
      if unsupported
        render json: { error: "Unsupported platform: #{unsupported}. Supported: ios, android, desktop" }, status: :bad_request
        return
      end

      params[:platforms].each do |platform, config|
        variation = config[:variation] || "phone"
        redirect = redirect_config.redirect_for_platform_and_variation(platform, variation)
        redirect.update!(
          fallback_url: config[:fallback_url],
          appstore: config[:appstore],
          enabled: config.fetch(:enabled, true)
        )
      end
    end

    render json: { redirect_config: RedirectConfigSerializer.serialize(redirect_config.reload) }, status: :ok
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :bad_request
  end

  # PUT /api/v1/mcp/sdk
  def setup_sdk
    platforms = params.require(:platforms)

    unsupported = platforms.keys.find { |p| !permitted_platform?(p) }
    if unsupported
      render json: { error: "Unsupported platform: #{unsupported}. Supported: ios, android, desktop" }, status: :bad_request
      return
    end

    results = {}

    platforms.each do |platform, config|
      app = PlatformConfigurationService.set_configuration(
        instance: @instance,
        platform: platform,
        enabled: config.fetch(:enabled, true),
        config_params: permitted_platform_config(platform, config.except(:enabled))
      )
      results[platform] = ApplicationSerializer.serialize(app)
    end

    render json: { configurations: results }, status: :ok
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :bad_request
  end

  private

  SUPPORTED_SDK_PLATFORMS = [Grovs::Platforms::IOS, Grovs::Platforms::ANDROID, Grovs::Platforms::DESKTOP].freeze

  def permitted_platform?(platform)
    SUPPORTED_SDK_PLATFORMS.include?(platform.to_s)
  end

  def permitted_platform_config(platform, config)
    case platform.to_s
    when Grovs::Platforms::IOS
      config.permit(:bundle_id, :app_prefix, :tablet_enabled)
    when Grovs::Platforms::ANDROID
      config.permit(:identifier, :tablet_enabled, sha256s: [])
    when Grovs::Platforms::DESKTOP
      config.permit(:generated_page, :fallback_url, :mac_uri, :windows_uri, :mac_enabled, :windows_enabled)
    end
  end
end
