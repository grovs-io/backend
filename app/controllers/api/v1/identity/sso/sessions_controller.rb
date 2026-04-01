# app/controllers/api/v1/identity/sso/sessions_controller.rb

class Api::V1::Identity::Sso::SessionsController < ApplicationController

  # Initiate OmniAuth
  def passthru
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

    user = SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
    return_access_token_for_user(user)
  rescue StandardError => e
    redirect_to_with_error(e.message)
  end

  def omniauth_failure
    redirect_to ENV["SSO_AUTHENTICATION_ENDPOINT"], allow_other_host: true
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
