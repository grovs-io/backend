require_relative "../../../test/contracts/external_api_contracts"

module ApiContracts
  SSO_DOMAIN = strict_object(required: %w[domain verified_at record_name record_value],
                             properties: { "domain" => STRING, "verified_at" => STRING_OR_NULL, "record_name" => STRING, "record_value" => STRING })

  SSO_CONNECTION = strict_object(
    required: %w[id issuer client_id client_secret_set client_secret_expires_at client_secret_expires_soon domains enforce jit_provision
                 admin_claim_value scim enabled active redirect_uri created_at updated_at],
    properties: {
      "id" => { "type" => "integer" }, "issuer" => STRING, "client_id" => STRING, "client_secret_set" => { "type" => "boolean" },
      "client_secret_expires_at" => STRING_OR_NULL, "client_secret_expires_soon" => { "type" => "boolean" },
      "domains" => { "type" => "array", "items" => SSO_DOMAIN }, "enforce" => { "type" => "boolean" },
      "jit_provision" => { "type" => "boolean" }, "admin_claim_value" => STRING_OR_NULL,
      "scim" => strict_object(required: %w[enabled base_url token_set last_used_at],
                              properties: { "enabled" => { "type" => "boolean" }, "base_url" => STRING, "token_set" => { "type" => "boolean" },
                                            "last_used_at" => STRING_OR_NULL }),
      "enabled" => { "type" => "boolean" }, "active" => { "type" => "boolean" }, "redirect_uri" => STRING,
      "created_at" => STRING, "updated_at" => STRING
    }
  )

  SSO_CONNECTION_RESPONSE = strict_object(required: %w[sso_connection],
                                          properties: { "sso_connection" => { "anyOf" => [SSO_CONNECTION, { "type" => "null" }] },
                                                        "sessions_revoked" => { "type" => "integer" } })

  register "Api::V1::SsoConnectionsController#show", request: NO_PARAMS,
           responses: { 200 => SSO_CONNECTION_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::SsoConnectionsController#upsert",
           request: strict_object(required: [], properties: {
                                    "issuer" => STRING, "client_id" => STRING, "client_secret" => STRING, "client_secret_expires_at" => STRING_OR_NULL,
                                    "domains" => { "type" => "array", "items" => STRING }, "enforce" => { "type" => %w[boolean string] },
                                    "jit_provision" => { "type" => %w[boolean string] }, "admin_claim_value" => STRING_OR_NULL,
                                    "enabled" => { "type" => %w[boolean string] },
                                    "sso_connection" => ANY_OBJECT # Rails JSON param wrapping
                                  }),
           responses: { 200 => SSO_CONNECTION_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR, 409 => ERROR, 422 => ERROR }
  register "Api::V1::SsoConnectionsController#destroy", request: NO_PARAMS,
           responses: { 200 => MESSAGE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR, 409 => ERROR }
  register "Api::V1::SsoConnectionsController#verify_domains", request: NO_PARAMS,
           responses: { 200 => SSO_CONNECTION_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR, 409 => ERROR }
  register "Api::V1::SsoConnectionsController#create_scim_token", request: NO_PARAMS,
           responses: { 201 => strict_object(required: %w[token], properties: { "token" => STRING }),
                        401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::SsoConnectionsController#destroy_scim_token", request: NO_PARAMS,
           responses: { 200 => MESSAGE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
end
