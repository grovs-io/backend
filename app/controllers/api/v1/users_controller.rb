class Api::V1::UsersController < ApplicationController
  before_action :doorkeeper_authorize!, except: [:create, :reset_password, :change_password, :accept_invite]

  def create
    return if refuse_if_enforced(user_params[:email])

    # Public registration is closed when self-hosted; accept_invite stays open (token-authorized).
    return render(json: { error: "Sign-ups are disabled" }, status: :forbidden) if Grovs.self_hosted?

    client_app = Doorkeeper::Application.find_by(uid: client_id_param)
    return render(json: { error: "Invalid client ID" }, status: :forbidden) unless client_app

    user = UserAccountService.register(email: user_params[:email], password: user_params[:password], name: user_params[:name])
    # register also completes a pending invitation in place; a fresh sign-up has no instances and fans out to nothing.
    Audit.record_for_user(user: user, action: "user.invite_accepted", actor: AuditActor.user(user, via: "password"))
    respond_with_auth_token_for_user(user, client_app)
  rescue ArgumentError
    render(json: { error: "An account with this email already exists" }, status: :conflict)
  end

  def reset_password
    return if refuse_if_enforced(user_params[:email])

    user = nil
    begin
      user = UserAccountService.request_password_reset(email: user_params[:email])
    rescue StandardError => e
      Rails.logger.error("reset_password error: #{e.class} - #{e.message}")
    end
    # Outside the rescue: an audit failure must not be swallowed into "Email sent".
    Audit.record_for_user(user: user, action: "user.password_reset_requested", actor: AuditActor.user(user, via: "password")) if user
    render json: { message: "Email sent" }, status: :ok
  end

  def change_password
    return if refuse_if_enforced(User.with_reset_password_token(change_password_params["reset_token"])&.email)

    user = UserAccountService.reset_password(token: change_password_params["reset_token"], new_password: change_password_params[:new_password])
    Audit.record_for_user(user: user, action: "user.password_changed", actor: AuditActor.user(user, via: "password"))
    render json: { message: "Password changed" }, status: :ok
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Invalid data" }, status: :not_found
  end

  def accept_invite
    return if refuse_if_enforced(User.find_by_invitation_token(accept_invite_params[:invitation_token], true)&.email)

    client_app = Doorkeeper::Application.find_by(uid: client_id_param)
    return render(json: { error: "Invalid client ID" }, status: :forbidden) unless client_app

    user = UserAccountService.accept_invite(
      invitation_token: accept_invite_params[:invitation_token],
      password: accept_invite_params[:password],
      name: accept_invite_params[:name]
    )

    if user
      Audit.record_for_user(user: user, action: "user.invite_accepted", actor: AuditActor.user(user, via: "password"))
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
    # Recorded first: after destroy_account the roles are gone and the fan-out would find no instances.
    ActiveRecord::Base.transaction do
      Audit.record_for_user(user: current_user, action: "user.account_deleted", actor: audit_actor)
      UserAccountService.destroy_account(user: current_user)
    end
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
      action = ActiveModel::Type::Boolean.new.cast(enable_2fa_param) ? "user.2fa_enabled" : "user.2fa_disabled"
      Audit.record_for_user(user: user, action: action, actor: audit_actor)
      render json: { user: UserSerializer.serialize(user) }, status: :ok
    else
      render json: { error: "Wrong OTP code" }, status: :forbidden
    end
  end

  private

  def refuse_if_enforced(email)
    id = email.present? && SsoEnforcement.enforced_connection_id(email)
    return false unless id

    render json: SsoEnforcement.refusal_body(id), status: :forbidden
    true
  end

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
