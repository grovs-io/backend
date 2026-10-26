require_relative "../../../test/contracts/external_api_contracts"
require_relative "experiment_schemas"

module ApiContracts
  JOURNEY_STEP = { "type" => "object", "required" => %w[id type], "properties" => { "id" => STRING, "type" => STRING } }.freeze
  JOURNEY_STEPS = { "type" => "object", "additionalProperties" => JOURNEY_STEP }.freeze
  JOURNEY_EVENT = { "type" => %w[object null], "properties" => { "name" => STRING_OR_NULL, "screen" => STRING_OR_NULL, "system" => STRING_OR_NULL,
                                                                   "filters" => ARRAY_OR_NULL } }.freeze
  JOURNEY_ENTRY = strict_object(required: %w[type event segment_id audience_segment_id],
                                properties: { "type" => STRING_OR_NULL, "event" => JOURNEY_EVENT, "segment_id" => STRING_OR_NULL,
                                              "audience_segment_id" => STRING_OR_NULL })
  JOURNEY_RE_ENTRY = strict_object(required: %w[mode days], properties: { "mode" => STRING, "days" => INT_OR_NULL })
  JOURNEY_STATS = strict_object(required: %w[active entered], properties: { "active" => { "type" => "integer" }, "entered" => { "type" => "integer" } })
  JOURNEY_FIELDS = {
    "id" => STRING, "name" => STRING, "status" => STRING, "revision" => { "type" => "integer" }, "lock_version" => { "type" => "integer" },
    "entry" => JOURNEY_ENTRY, "re_entry" => JOURNEY_RE_ENTRY, "goals" => { "type" => "array", "items" => GOAL },
    "control_group" => INT_OR_NULL, "start_at" => STRING_OR_NULL, "end_at" => STRING_OR_NULL, "first_step" => STRING_OR_NULL,
    "launched_at" => STRING_OR_NULL, "ended_at" => STRING_OR_NULL,
    "created_at" => STRING, "updated_at" => STRING
  }.freeze
  JOURNEY_SLIM = strict_object(required: JOURNEY_FIELDS.keys + ["stats"], properties: JOURNEY_FIELDS.merge("stats" => JOURNEY_STATS))
  JOURNEY = strict_object(required: JOURNEY_FIELDS.keys + ["steps"], properties: JOURNEY_FIELDS.merge("steps" => JOURNEY_STEPS))
  JOURNEY_ONE = strict_object(required: %w[journey], properties: { "journey" => JOURNEY })
  JOURNEY_REQUEST = strict_object(
    required: [],
    properties: { "name" => STRING, "entry" => OBJECT_OR_NULL, "re_entry" => OBJECT_OR_NULL, "goals" => ARRAY, "control_group" => INT_OR_NULL,
                  "start_at" => STRING_OR_NULL, "end_at" => STRING_OR_NULL, "first_step" => STRING_OR_NULL, "steps" => JOURNEY_STEPS,
                  "lock_version" => { "type" => "integer" } }
  )
  JOURNEY_ERRORS = { 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }.freeze
  JOURNEY_COUNT = { "type" => "integer" }.freeze
  JOURNEY_REPORT = strict_object(
    required: %w[entered held active left steps goal paths],
    properties: {
      "entered" => JOURNEY_COUNT, "held" => JOURNEY_COUNT, "active" => JOURNEY_COUNT,
      "left" => strict_object(required: %w[finished goal expired], properties: %w[finished goal expired].index_with { JOURNEY_COUNT }),
      "steps" => { "type" => "object", "additionalProperties" => strict_object(
        required: %w[reached now branches],
        properties: { "reached" => JOURNEY_COUNT, "now" => JOURNEY_COUNT, "branches" => { "type" => "object", "additionalProperties" => JOURNEY_COUNT } }
      ) },
      "goal" => { "oneOf" => [{ "type" => "null" }, EXPERIMENT] },
      "paths" => { "type" => "object", "additionalProperties" => EXPERIMENT }
    }
  )

  register "Api::V1::JourneysController#index",
           responses: JOURNEY_ERRORS.merge(200 => strict_object(required: %w[journeys truncated next_after],
                                                                properties: { "journeys" => { "type" => "array", "items" => JOURNEY_SLIM },
                                                                              "truncated" => BOOL, "next_after" => STRING_OR_NULL }),
                                           422 => ERROR)
  register "Api::V1::JourneysController#show", responses: JOURNEY_ERRORS.merge(200 => JOURNEY_ONE)
  register "Api::V1::JourneysController#create", request: JOURNEY_REQUEST, responses: JOURNEY_ERRORS.merge(201 => JOURNEY_ONE, 422 => ERROR)
  register "Api::V1::JourneysController#update", request: JOURNEY_REQUEST,
                                                 responses: JOURNEY_ERRORS.merge(200 => JOURNEY_ONE, 409 => ERROR, 422 => ERROR)
  register "Api::V1::JourneysController#destroy", responses: JOURNEY_ERRORS.merge(200 => MESSAGE, 409 => ERROR)
  register "Api::V1::JourneysController#launch", responses: JOURNEY_ERRORS.merge(200 => JOURNEY_ONE, 409 => ERROR, 422 => ERROR)
  register "Api::V1::JourneysController#pause", responses: JOURNEY_ERRORS.merge(200 => JOURNEY_ONE, 409 => ERROR)
  register "Api::V1::JourneysController#resume", responses: JOURNEY_ERRORS.merge(200 => JOURNEY_ONE, 409 => ERROR)
  register "Api::V1::JourneysController#finish", responses: JOURNEY_ERRORS.merge(200 => JOURNEY_ONE, 409 => ERROR)
  register "Api::V1::JourneysController#duplicate", responses: JOURNEY_ERRORS.merge(201 => JOURNEY_ONE, 422 => ERROR)
  JOURNEY_IMAGE = strict_object(required: %w[url lock_version], properties: { "url" => STRING, "lock_version" => { "type" => "integer" } })
  JOURNEY_UPLOAD = strict_object(required: [], properties: { "image" => JSON_VALUE, "lock_version" => JSON_VALUE })
  register "Api::V1::JourneysController#upload_image", request: JOURNEY_UPLOAD,
                                                       responses: JOURNEY_ERRORS.merge(201 => JOURNEY_IMAGE, 409 => ERROR, 422 => ERROR)
  register "Api::V1::JourneysController#report",
           responses: JOURNEY_ERRORS.merge(
             200 => strict_object(required: %w[report], properties: { "report" => JOURNEY_REPORT }),
             422 => ERROR, 503 => strict_object(required: %w[error error_code], properties: { "error" => STRING, "error_code" => STRING })
           )
end
