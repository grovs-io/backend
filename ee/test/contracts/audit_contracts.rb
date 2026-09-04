require_relative "../../../test/contracts/external_api_contracts"

module ApiContracts
  AUDIT_ACTOR = strict_object(required: %w[type id email via],
                              properties: { "type" => STRING, "id" => { "type" => %w[integer string null] },
                                            "email" => STRING_OR_NULL, "via" => STRING_OR_NULL })

  AUDIT_EVENT = strict_object(
    required: %w[id sequence occurred_at action outcome actor target changes ip user_agent request_id prev_hash hash],
    properties: {
      "id" => { "type" => "integer" }, "sequence" => { "type" => "integer" }, "occurred_at" => STRING,
      "action" => STRING, "outcome" => STRING, "actor" => AUDIT_ACTOR, "target" => ANY_OBJECT,
      "changes" => ANY_OBJECT, "ip" => STRING_OR_NULL, "user_agent" => STRING_OR_NULL,
      "request_id" => STRING_OR_NULL, "prev_hash" => STRING_OR_NULL, "hash" => STRING
    }
  )

  AUDIT_EVENTS_RESPONSE = strict_object(
    required: %w[schema_version events next_after next_before],
    properties: { "schema_version" => { "type" => "integer" },
                  "events" => { "type" => "array", "items" => AUDIT_EVENT },
                  "next_after" => INTEGER_OR_NULL, "next_before" => INTEGER_OR_NULL }
  )

  AUDIT_HEAD_RESPONSE = strict_object(
    required: %w[schema_version sequence hash],
    properties: { "schema_version" => { "type" => "integer" }, "sequence" => { "type" => "integer" }, "hash" => STRING_OR_NULL }
  )

  AUDIT_EXPORT_TOKEN = strict_object(
    required: %w[id name created_at last_used_at created_by_email],
    properties: { "id" => STRING, "name" => STRING, "created_at" => STRING, "last_used_at" => STRING_OR_NULL, "created_by_email" => STRING_OR_NULL }
  )

  register "Api::V1::AuditEventsController#index",
           request: strict_object(required: [], properties: {
                                    "after" => { "type" => %w[integer string] }, "before" => { "type" => %w[integer string] },
                                    "limit" => { "type" => %w[integer string] }, "order" => STRING,
                                    "event_action" => STRING, "actor_email" => STRING, "from" => STRING, "to" => STRING
                                  }),
           responses: { 200 => AUDIT_EVENTS_RESPONSE, 400 => ERROR, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::AuditEventsController#latest", request: NO_PARAMS,
           responses: { 200 => AUDIT_HEAD_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }

  register "Api::V1::AuditExportTokensController#index", request: NO_PARAMS,
           responses: { 200 => strict_object(required: %w[audit_export_tokens],
                                             properties: { "audit_export_tokens" => { "type" => "array", "items" => AUDIT_EXPORT_TOKEN } }),
                        401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::AuditExportTokensController#create",
           request: strict_object(required: [], properties: { "name" => STRING_OR_NULL }),
           responses: { 201 => strict_object(required: %w[audit_export_token token],
                                             properties: { "audit_export_token" => AUDIT_EXPORT_TOKEN, "token" => STRING }),
                        401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR, 422 => ERROR }
  register "Api::V1::AuditExportTokensController#destroy", request: NO_PARAMS,
           responses: { 200 => MESSAGE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
end
