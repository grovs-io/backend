class Api::V1::UsersController < ApplicationController
  before_action :doorkeeper_authorize!, except: [:create, :reset_password, :change_password, :accept_invite]

  def create
    client_app = Doorkeeper::Application.find_by(uid: client_id_param)
    return render(json: { error: "Invalid client ID" }, status: :forbidden) unless client_app

    user = UserAccountService.register(email: user_params[:email], password: user_params[:password], name: user_params[:name])
    respond_with_auth_token_for_user(user, client_app)
  rescue ArgumentError
    render(json: { error: "An account with this email already exists" }, status: :conflict)
  end

  def reset_password
    begin
      UserAccountService.request_password_reset(email: user_params[:email])
    rescue StandardError => e
      Rails.logger.error("reset_password error: #{e.class} - #{e.message}")
    end
    render json: { message: "Email sent" }, status: :ok
  end

  def change_password
    UserAccountService.reset_password(token: change_password_params["reset_token"], new_password: change_password_params[:new_password])
    render json: { message: "Password changed" }, status: :ok
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Invalid data" }, status: :not_found
  end

  def accept_invite
    client_app = Doorkeeper::Application.find_by(uid: client_id_param)
    return render(json: { error: "Invalid client ID" }, status: :forbidden) unless client_app

    user = UserAccountService.accept_invite(
      invitation_token: accept_invite_params[:invitation_token],
      password: accept_invite_params[:password],
      name: accept_invite_params[:name]
    )

    if user
      respond_with_auth_token_for_user(user, client_app)
    else
      render(json: { error: "Can not create account" }, status: :unprocessable_entity)
    end
  end

  def current_user_details
    render json: { user: UserSerializer.serialize(current_user, show_roles: true) }, status: :ok
  end

  def edit_user
    UserAccountService.update_profile(user: current_user, attrs: name_param)
    render json: { user: UserSerializer.serialize(current_user, show_roles: true) }, status: :ok
  end

  def remove_user
    UserAccountService.destroy_account(user: current_user)
    render json: { message: "User and associated roles deleted!" }, status: :ok
  end

  # 2FA

  def otp_enabled
    render json: { otp_enabled: current_user.otp_required_for_login? }
  end

  def otp_qr
    provisioning_uri = UserAccountService.setup_2fa(user: current_user)
    qrcode = RQRCode::QRCode.new(provisioning_uri)
    svg = qrcode.as_svg(viewbox: { width: 150 })
    render plain: svg
  end

  def set_2fa_enabled
    user = UserAccountService.toggle_2fa(user: current_user, enable: enable_2fa_param, otp_code: otp_code_param)
    if user
      render json: { user: UserSerializer.serialize(user) }, status: :ok
    else
      render json: { error: "Wrong OTP code" }, status: :forbidden
    end
  end

  private

  def user_params
    params.permit(:email, :password, :name)
  end

  def accept_invite_params
    params.permit(:password, :invitation_token, :name)
  end

  def change_password_params
    params.permit(:new_password, :reset_token, user: {})
  end

  def client_id_param
    params.require(:client_id)
  end

  def name_param
    params.permit(:name)
  end

  def enable_2fa_param
    params.require(:enable_2fa)
  end

  def otp_code_param
    params.require(:otp_code)
  end

  def respond_with_auth_token_for_user(user, client_app)
    access_token = TokenServices.generate_sso_access_token(user)

    render(json: {
      user: UserSerializer.serialize(user),
      access_token: access_token.token,
      token_type: "bearer",
      expires_in: access_token.expires_in,
      refresh_token: access_token.refresh_token,
      created_at: access_token.created_at.to_time.to_i
    })
  end
end
