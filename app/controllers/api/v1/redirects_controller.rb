class Api::V1::RedirectsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project
  rescue_from ActiveRecord::RecordInvalid, with: :render_validation_error

  def redirect_config
    render json: {redirect_config: RedirectConfigSerializer.serialize(@project.redirect_config)}, status: :ok
  end

  def set_redirect_config
    redirect_config = @project.redirect_config
    unless redirect_config
      redirect_config = RedirectConfig.new(redirect_config_params)
      redirect_config.project = @project
      redirect_config.save!

      render json: {redirect_config: RedirectConfigSerializer.serialize(redirect_config)}, status: :ok
      return
    end

    redirect_config.update(redirect_config_params)
    render json: {redirect_config: redirect_config}, status: :ok
  end

  def set_redirect
    redirect_config = @project.redirect_config
    unless redirect_config
      render json: {error: "You need to configure the fallback URL first!"}, status: :unprocessable_entity
      return
    end

    redirect = redirect_config.redirect_for_platform_and_variation(platform_param, variation_param)
    redirect.update!(redirect_params)

    fallback = redirect_params[:fallback_url]
    enabled = redirect_params[:enabled]
    if fallback.blank? && !enabled
      redirect.destroy!
    end

    render json: {config: RedirectConfigSerializer.serialize(redirect_config)}, status: :ok
  end

  private

  # Params

  def platform_param
    params.require(:platform)
  end

  def variation_param
    params.require(:variation)
  end

  def redirect_params
    params.permit(:appstore, :fallback_url, :enabled)
  end

  def redirect_config_params
    params.permit(:default_fallback, :show_preview_android, :show_preview_ios)
  end

  def render_validation_error(exception)
    render json: { error: exception.message }, status: :unprocessable_entity
  end
end