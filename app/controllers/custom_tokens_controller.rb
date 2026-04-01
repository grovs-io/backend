class CustomTokensController < Doorkeeper::TokensController
  def create
    if params[:grant_type] == "refresh_token"
      token = Doorkeeper::AccessToken.by_refresh_token(params[:refresh_token])
      if !token || token.revoked? || token.created_at < 7.days.ago
        render json: { error: "invalid_grant", error_description: "The refresh token is invalid or expired." },
               status: :bad_request
        return
      end
    end

    super
  rescue OtpRequiredError
    render json: { requires_otp: true }, status: :ok
  end
end
