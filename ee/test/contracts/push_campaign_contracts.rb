require_relative "../../../test/contracts/external_api_contracts"
require_relative "../../../test/contracts/push_campaign_schemas"
require_relative "experiment_schemas"

module ApiContracts
  PUSH_AUDIENCE_REQUEST = strict_object(
    required: [],
    properties: { "type" => STRING, "recipients" => { "type" => "array", "items" => STRING }, "segment_id" => STRING_OR_NULL }
  )
  PUSH_ONE = strict_object(required: %w[push_campaign], properties: { "push_campaign" => PUSH_CAMPAIGN })
  PUSH_REQUEST = strict_object(
    required: [],
    properties: { "name" => STRING, "title" => STRING, "body" => STRING, "image_url" => STRING_OR_NULL, "image" => JSON_VALUE, "sound" => STRING_OR_NULL,
                  "data" => JSON_VALUE, "link_id" => { "type" => %w[integer string null] },
                  "control_group" => { "type" => %w[integer string null] }, "test_share" => { "type" => %w[integer string null] },
                  "winner_after_minutes" => { "type" => %w[integer string null] }, "winner_by" => STRING_OR_NULL,
                  "conversion" => JSON_VALUE, "variants" => JSON_VALUE,
                  "audience" => PUSH_AUDIENCE_REQUEST }
  )
  PUSH_ERRORS = { 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }.freeze
  PUSH_ESTIMATE_AUDIENCE_REQUEST = {
    "type" => "object", "additionalProperties" => true, "required" => [], "properties" => { "audience" => PUSH_AUDIENCE_REQUEST }
  }.freeze
  # devices/no_app/reachable are null together when the ClickHouse split was too heavy to compute.
  PUSH_PLATFORM_BREAKDOWN = strict_object(required: %w[devices configured], properties: { "devices" => { "type" => %w[integer null] },
                                                                                          "configured" => { "type" => "boolean" } })
  PUSH_ESTIMATE_RESPONSE = strict_object(
    required: %w[devices no_channel not_found no_app reachable platforms],
    properties: { "devices" => { "type" => "integer" }, "no_channel" => { "type" => "integer" }, "not_found" => { "type" => "integer" },
                  "persons" => { "type" => "integer" }, "incomplete" => { "type" => "boolean" },
                  "no_app" => { "type" => %w[integer null] }, "reachable" => { "type" => %w[integer null] },
                  "platforms" => strict_object(required: %w[ios android],
                                               properties: { "ios" => PUSH_PLATFORM_BREAKDOWN, "android" => PUSH_PLATFORM_BREAKDOWN }) }
  )
  PUSH_DELIVERY = strict_object(
    required: %w[id status platform recipient error opened_at visitor],
    properties: { "id" => { "type" => "integer" }, "status" => STRING, "platform" => STRING_OR_NULL, "recipient" => STRING_OR_NULL,
                  "error" => STRING_OR_NULL, "opened_at" => STRING_OR_NULL,
                  "visitor" => { "anyOf" => [strict_object(required: VISITOR_SLIM_PROPERTIES.keys, properties: VISITOR_SLIM_PROPERTIES),
                                             { "type" => "null" }] } }
  )

  register "Api::V1::PushCampaignsController#index",
           responses: PUSH_ERRORS.merge(200 => strict_object(required: %w[push_campaigns truncated next_after],
                                                             properties: { "push_campaigns" => { "type" => "array", "items" => PUSH_CAMPAIGN },
                                                                           "truncated" => { "type" => "boolean" },
                                                                           "next_after" => { "type" => %w[string null] } }),
                                        422 => ERROR)
  register "Api::V1::PushCampaignsController#show", responses: PUSH_ERRORS.merge(200 => PUSH_ONE)
  register "Api::V1::PushCampaignsController#create", request: PUSH_REQUEST, responses: PUSH_ERRORS.merge(201 => PUSH_ONE, 422 => ERROR)
  register "Api::V1::PushCampaignsController#update", request: PUSH_REQUEST, responses: PUSH_ERRORS.merge(200 => PUSH_ONE, 409 => ERROR, 422 => ERROR)
  register "Api::V1::PushCampaignsController#send_now",
           request: strict_object(required: [], properties: { "scheduled_at" => STRING_OR_NULL, "local_time" => { "type" => "boolean" },
                                                              "timezone" => STRING_OR_NULL }),
           responses: PUSH_ERRORS.merge(202 => PUSH_ONE, 409 => ERROR, 422 => ERROR)
  register "Api::V1::PushCampaignsController#cancel", responses: PUSH_ERRORS.merge(200 => PUSH_ONE, 409 => ERROR)
  register "Api::V1::PushCampaignsController#send_winner", request: strict_object(required: [], properties: { "variant" => STRING }),
                                                           responses: PUSH_ERRORS.merge(202 => PUSH_ONE, 409 => ERROR, 422 => ERROR)
  register "Api::V1::PushCampaignsController#experiment",
           responses: PUSH_ERRORS.merge(200 => strict_object(required: %w[experiment], properties: { "experiment" => EXPERIMENT }),
                                        422 => ERROR, 503 => PUSH_CODED_ERROR)
  register "Api::V1::PushCampaignsController#remove_image", responses: PUSH_ERRORS.merge(200 => PUSH_ONE, 409 => ERROR)
  register "Api::V1::PushCampaignsController#estimate",
           responses: PUSH_ERRORS.merge(200 => PUSH_ESTIMATE_RESPONSE, 422 => PUSH_CODED_ERROR, 429 => PUSH_CODED_ERROR, 503 => PUSH_CODED_ERROR)
  # 422 covers both our own audience-validation errors and the coded segment errors.
  register "Api::V1::PushCampaignsController#estimate_audience",
           request: PUSH_ESTIMATE_AUDIENCE_REQUEST,
           responses: PUSH_ERRORS.merge(200 => PUSH_ESTIMATE_RESPONSE, 422 => { "oneOf" => [ERROR, PUSH_CODED_ERROR] },
                                        429 => PUSH_CODED_ERROR, 503 => PUSH_CODED_ERROR)
  register "Api::V1::PushCampaignsController#deliveries",
           responses: PUSH_ERRORS.merge(200 => strict_object(required: %w[deliveries next_after],
                                                             properties: { "deliveries" => { "type" => "array", "items" => PUSH_DELIVERY },
                                                                           "next_after" => { "type" => %w[integer null] } }),
                                        422 => ERROR)
end
