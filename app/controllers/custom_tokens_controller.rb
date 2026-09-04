class CustomTokensController < Doorkeeper::TokensController
  include AuditContext
  skip_before_action :validate_presence_of_client, only: [:revoke]
  before_action :refuse_enforced_password_login, only: [:create]

  # RFC 7009 wants client auth, but the SPA only holds the token, and holding it grants access.
  def revoke
    if self_revocable_token
      unless self_revocable_token.revoked?
        self_revocable_token.revoke
        audit_logout(self_revocable_token)
      end
      render json: {}, status: :ok
    else
      super
    end
  end

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
    audit_password_login if params[:grant_type] == "password"
  rescue OtpRequiredError
    render json: { requires_otp: true }, status: :ok
  end

  private

  def refuse_enforced_password_login
    return unless params[:grant_type] == "password"

    id = SsoEnforcement.enforced_connection_id(params[:email])
    render(json: SsoEnforcement.refusal_body(id), status: :forbidden) if id
  end

  def audit_password_login
    auth = authorize_response
    if auth.is_a?(Doorkeeper::OAuth::ErrorResponse)
      # invalid_client (a misconfigured SPA) is not a failed login by the user.
      return unless auth.body[:error].to_s == "invalid_grant"

      user = User.find_for_email(params[:email])
      return unless user

      Audit.record_for_user(user: user, action: "user.login_failed", outcome: "failure",
                                 actor: AuditActor.user(user, via: "password"))
    else
      user = User.find_by(id: auth.token.resource_owner_id)
      Audit.record_for_user(user: user, action: "user.login", actor: AuditActor.user(user, via: "password")) if user
    end
  end

  def audit_logout(token)
    user = token && User.find_by(id: token.resource_owner_id)
    return unless user

    Audit.record_for_user(user: user, action: "user.logout", actor: AuditActor.user(user, via: "dashboard"))
  end

  def revocable_token_for_audit
    raw = params[:token].presence
    raw && (Doorkeeper::AccessToken.by_token(raw) || Doorkeeper::AccessToken.by_refresh_token(raw))
  end

  def self_revocable_token
    return @self_revocable_token if defined?(@self_revocable_token)

    @self_revocable_token = revocable_token_for_audit
  end
end
