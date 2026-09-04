# Core entry point for enterprise SSO; the implementation lives in ee/, a no-op without it.
module SsoEnforcement
  REFUSAL = "Sign in with your organisation's SSO.".freeze

  module_function

  def enabled? = defined?(SsoConnection) ? true : false

  def enforced_connection_id(email)
    return nil unless enabled?

    conn = SsoConnection.for_domain(SsoConnection.domain_of(email))
    return nil unless conn&.enforce
    return nil if User.find_for_email(email)&.super_admin?

    conn.id
  end

  def refusal_body(connection_id) = { error: REFUSAL, sso_connection_id: connection_id }

  def discover(email)
    return { connection_id: nil } unless enabled?

    SsoConnection.discover(email)
  end

  def start_url(connection_id, email: nil)
    return nil unless enabled?

    SsoConnection.start_url(connection_id, email: email)
  end

  def enterprise_login(auth_hash:, connection:)
    SsoConnections::EnterpriseLogin.call(auth_hash: auth_hash, connection: connection)
  end
end
