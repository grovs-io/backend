require_relative "external_api_contracts"

# Push campaign shapes live in core: the server SDK endpoints exist in both editions.
module ApiContracts
  PUSH_REPORT = strict_object(
    required: %w[targeted no_channel not_found queued delivered failed opened cancelled held waiting error_counts audience],
    properties: { "targeted" => { "type" => "integer" }, "no_channel" => { "type" => "integer" }, "not_found" => { "type" => "integer" },
                  "held" => { "type" => "integer" }, "waiting" => { "type" => "integer" },
                  "queued" => { "type" => "integer" }, "delivered" => { "type" => "integer" }, "failed" => { "type" => "integer" },
                  "opened" => { "type" => "integer" }, "cancelled" => { "type" => "integer" }, "error_counts" => ANY_OBJECT,
                  "audience" => strict_object(required: %w[persons devices incomplete],
                                              properties: { "persons" => { "type" => %w[integer null] }, "devices" => { "type" => %w[integer null] },
                                                            "incomplete" => { "type" => "boolean" } }) }
  )
  PUSH_AUDIENCE = strict_object(
    required: %w[type recipients_count segment_id segment_definition_hash],
    properties: { "type" => STRING, "recipients_count" => { "type" => "integer" }, "recipients" => { "type" => "array", "items" => STRING },
                  "segment_id" => STRING_OR_NULL, "segment_definition_hash" => STRING_OR_NULL }
  )
  PUSH_CAMPAIGN = strict_object(
    required: %w[id name title body image_url image sound data link_id source status scheduled_at local_time timezone evaluated_at
                 started_at finished_at failure_reason audience report created_at updated_at control_group conversion variants test_share
                 winner_after_minutes winner_by winner_due_at winner],
    properties: { "id" => STRING, "name" => STRING, "title" => STRING, "body" => STRING, "image_url" => STRING_OR_NULL, "image" => STRING_OR_NULL,
                  "sound" => STRING_OR_NULL, "data" => ANY_OBJECT, "link_id" => { "type" => %w[integer null] }, "source" => STRING, "status" => STRING,
                  "scheduled_at" => STRING_OR_NULL, "local_time" => { "type" => "boolean" }, "timezone" => STRING, "evaluated_at" => STRING_OR_NULL,
                  "started_at" => STRING_OR_NULL, "finished_at" => STRING_OR_NULL, "failure_reason" => STRING_OR_NULL,
                  "audience" => PUSH_AUDIENCE, "report" => PUSH_REPORT, "created_at" => STRING, "updated_at" => STRING,
                  "control_group" => { "type" => %w[integer null] }, "test_share" => { "type" => %w[integer null] },
                  "winner_after_minutes" => { "type" => %w[integer null] }, "winner_by" => STRING_OR_NULL, "winner_due_at" => STRING_OR_NULL,
                  "winner" => STRING_OR_NULL,
                  "conversion" => { "oneOf" => [{ "type" => "null" },
                                                { "type" => "object", "additionalProperties" => false, "required" => %w[window_hours],
                                                  "minProperties" => 2, "maxProperties" => 2,
                                                  "properties" => { "event" => STRING, "screen" => STRING, "window_hours" => { "type" => "integer" } } }] },
                  "variants" => { "oneOf" => [{ "type" => "null" }, { "type" => "array", "items" => strict_object(
                    required: %w[id title body], properties: { "id" => STRING, "title" => STRING, "body" => STRING }
                  ) }] } }
  )
  PUSH_CODED_ERROR = strict_object(required: %w[error error_code], properties: { "error" => STRING, "error_code" => STRING })
  PUSH_SERVER_REQUEST = strict_object(
    required: [],
    properties: { "name" => STRING_OR_NULL, "title" => STRING, "body" => STRING, "image_url" => STRING_OR_NULL, "sound" => STRING_OR_NULL,
                  "link_id" => { "type" => %w[integer string null] }, "data" => JSON_VALUE,
                  "audience" => strict_object(required: %w[type], properties: { "type" => STRING, "recipients" => { "type" => "array", "items" => STRING },
                                                                             "segment_id" => STRING_OR_NULL }),
                  "scheduled_at" => STRING_OR_NULL, "local_time" => { "type" => "boolean" }, "timezone" => STRING_OR_NULL }
  )
end
