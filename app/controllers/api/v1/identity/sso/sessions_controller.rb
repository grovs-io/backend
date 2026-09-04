# app/controllers/api/v1/identity/sso/sessions_controller.rb

class Api::V1::Identity::Sso::SessionsController < ApplicationController

  # Lets the dashboard render only the providers this deployment has configured.
  def providers
    render json: {
      sso_enabled: SsoAuthenticationService.sso_enabled?,
      providers: SsoAuthenticationService.available_providers
    }, status: :ok
  end

  def discover
    render json: SsoEnforcement.discover(params[:email]), status: :ok
  end

  # Initiate OmniAuth
  def passthru
    if provider_param == Grovs::SSO::OIDC
      url = SsoEnforcement.start_url(params[:connection_id], email: params[:email])
      return render(json: { error: "Not found" }, status: :not_found) unless url

      return render(json: { redirect_url: url }, status: :ok)
    end

    auth_url = SsoAuthenticationService.build_auth_url(provider: provider_param)
    render json: { redirect_url: auth_url }, status: :ok
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # OmniAuth callback
  def create
    auth = request.env["omniauth.auth"]
    unless auth
      return render json: { error: "Invalid token" }, status: :unprocessable_entity
    end

    state = state_param
    unless SsoAuthenticationService.valid_state?(state: state)
      return redirect_to_with_error("Invalid or expired OAuth state")
    end

    user = if auth.provider == Grovs::SSO::OIDC
             SsoEnforcement.enterprise_login(auth_hash: auth, connection: request.env[Grovs::SSO::ENV_CONNECTION])
           else
             SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
           end
    Audit.record_for_user(user: user, action: "user.sso_login", actor: AuditActor.user(user, via: "sso:#{auth.provider}"))
    return_access_token_for_user(user)
  rescue RuntimeError => e
    redirect_to_with_error(e.message)
  rescue StandardError => e
    Rails.logger.error("[SSO] login error: #{e.class}")
    Rails.error.report(e, handled: true)
    redirect_to_with_error("Sign-in failed")
  end

  def omniauth_failure
    return redirect_to_with_error(oidc_failure_message) if request.env["omniauth.error.strategy"]&.name.to_s == Grovs::SSO::OIDC

    endpoint = ENV["SSO_AUTHENTICATION_ENDPOINT"].presence
    return redirect_to(endpoint, allow_other_host: true) if endpoint

    # Without a configured SSO endpoint the failure must still land somewhere: the dashboard, with the reason.
    redirect_to_with_error("SSO authentication failed")
  end

  private

  def target_host
    "#{ENV["REACT_HOST_PROTOCOL"]}#{ENV["REACT_HOST"]}"
  end

  def return_access_token_for_user(user)
    access_token  = TokenServices.generate_sso_access_token(user)
    token         = access_token.token
    refresh_token = access_token.refresh_token

    full_url = "#{target_host}?token=#{token}&refresh_token=#{refresh_token}"
    redirect_to full_url, allow_other_host: true
  end

  def oidc_failure_message
    case request.env[Grovs::SSO::ENV_SETUP_ERROR]
    when "inactive" then "Single sign-on is not available for this organisation."
    when "error" then "Sign-in failed"
    else "Your organisation's identity provider rejected the sign-in."
    end
  end

  def redirect_to_with_error(message)
    full_url = "#{target_host}?error=#{CGI.escape(message)}"
    Rails.logger.warn("[SSO] login rejected: #{message}")
    redirect_to full_url, allow_other_host: true
  end

  # Required/optional params
  def provider_param
    params.require(:provider)
  end

  def state_param
    params[:state]
  end
end
