class Api::V1::Identity::Sso::TokensController < ApplicationController

  # This action will handle the OmniAuth authentication initiation
  def refresh_token
    access_token = TokenServices.refresh_user_access_token(refresh_token_param)
    unless access_token
      render json: {error: "Token not valid"}, status: :unauthorized
      return
    end

    render json: {token: access_token.token, refresh_token: access_token.refresh_token}, status: :ok
  end

  private

  def refresh_token_param
    params.require(:refresh_token)
  end

end