class SsoConnectionSerializer
  # scim_base_url comes from the request: SCIM answers only on the API host, which SERVER_HOST may not name.
  def self.serialize(conn, scim_base_url:)
    {
      id: conn.id, issuer: conn.issuer, client_id: conn.client_id,
      client_secret_set: conn.client_secret.present?,
      client_secret_expires_at: conn.client_secret_expires_at,
      client_secret_expires_soon: conn.client_secret_expires_at.present? && conn.client_secret_expires_at < 30.days.from_now,
      domains: conn.domains.order(:id).map do |d|
        { domain: d.domain, verified_at: d.verified_at, record_name: d.record_name, record_value: d.record_value }
      end,
      enforce: conn.enforce, jit_provision: conn.jit_provision, admin_claim_value: conn.admin_claim_value,
      scim: { enabled: conn.scim_enabled, base_url: scim_base_url, token_set: conn.scim_token_digest.present?,
              last_used_at: conn.scim_last_used_at },
      enabled: conn.enabled, active: conn.active?,
      redirect_uri: SsoConnection.redirect_uri,
      created_at: conn.created_at, updated_at: conn.updated_at
    }
  end
end
