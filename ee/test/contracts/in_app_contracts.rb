require_relative "../../../test/contracts/external_api_contracts"
require_relative "experiment_schemas"

module ApiContracts
  IN_APP_AUDIENCE = strict_object(required: %w[type segment_id segment_definition_hash segment_changed],
                                  properties: { "type" => STRING, "segment_id" => STRING_OR_NULL, "segment_definition_hash" => STRING_OR_NULL,
                                                "segment_changed" => BOOL })
  IN_APP_CAMPAIGN = strict_object(
    required: %w[id name status revision template content triggers conditions caps schedule priority delay_seconds start_at end_at
                 launched_at ended_at failure_reason created_at updated_at audience lock_version control_group conversion variants],
    properties: { "id" => STRING, "name" => STRING, "status" => STRING, "revision" => { "type" => "integer" }, "template" => STRING,
                  "control_group" => { "type" => %w[integer null] }, "conversion" => { "type" => %w[object null] },
                  "variants" => { "type" => %w[array null] },
                  "content" => ANY_OBJECT, "triggers" => ARRAY, "conditions" => ARRAY, "caps" => ANY_OBJECT, "schedule" => ANY_OBJECT,
                  "priority" => { "type" => "integer" }, "delay_seconds" => { "type" => "integer" }, "start_at" => STRING_OR_NULL,
                  "end_at" => STRING_OR_NULL, "launched_at" => STRING_OR_NULL, "ended_at" => STRING_OR_NULL,
                  "failure_reason" => STRING_OR_NULL, "created_at" => STRING, "updated_at" => STRING, "audience" => IN_APP_AUDIENCE,
                  "lock_version" => { "type" => "integer" } }
  )
  IN_APP_ONE = strict_object(required: %w[in_app_campaign], properties: { "in_app_campaign" => IN_APP_CAMPAIGN })
  IN_APP_REQUEST = strict_object(
    required: [],
    properties: { "name" => STRING, "template" => STRING, "content" => JSON_VALUE, "triggers" => JSON_VALUE, "conditions" => JSON_VALUE,
                  "caps" => JSON_VALUE, "schedule" => JSON_VALUE, "priority" => { "type" => "integer" },
                  "delay_seconds" => { "type" => "integer" }, "start_at" => STRING_OR_NULL, "end_at" => STRING_OR_NULL,
                  "lock_version" => JSON_VALUE, "control_group" => { "type" => %w[integer null] }, "conversion" => JSON_VALUE,
                  "variants" => JSON_VALUE,
                  "audience" => strict_object(required: [], properties: { "type" => STRING, "segment_id" => STRING_OR_NULL }) }
  )
  IN_APP_ERRORS = { 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }.freeze
  IN_APP_SETTINGS = strict_object(
    required: %w[in_app_settings],
    properties: { "in_app_settings" => strict_object(required: %w[enabled session_cap day_cap control_group push_daily_cap],
                                                     properties: { "enabled" => BOOL, "session_cap" => { "type" => "integer" },
                                                                   "day_cap" => { "type" => "integer" }, "control_group" => { "type" => "integer" },
                                                                   "push_daily_cap" => { "type" => %w[integer null] } }) }
  )
  register "Api::V1::InAppCampaignsController#index",
           responses: IN_APP_ERRORS.merge(200 => strict_object(required: %w[in_app_campaigns truncated next_after],
                                                               properties: { "in_app_campaigns" => { "type" => "array", "items" => IN_APP_CAMPAIGN },
                                                                             "truncated" => BOOL, "next_after" => STRING_OR_NULL }),
                                          422 => ERROR)
  register "Api::V1::InAppCampaignsController#show", responses: IN_APP_ERRORS.merge(200 => IN_APP_ONE)
  register "Api::V1::InAppCampaignsController#create", request: IN_APP_REQUEST, responses: IN_APP_ERRORS.merge(201 => IN_APP_ONE, 422 => ERROR)
  register "Api::V1::InAppCampaignsController#update", request: IN_APP_REQUEST,
                                                       responses: IN_APP_ERRORS.merge(200 => IN_APP_ONE, 409 => ERROR, 422 => ERROR)
  register "Api::V1::InAppCampaignsController#destroy", responses: IN_APP_ERRORS.merge(200 => MESSAGE, 409 => ERROR)
  register "Api::V1::InAppCampaignsController#launch", responses: IN_APP_ERRORS.merge(202 => IN_APP_ONE, 409 => ERROR, 422 => ERROR)
  register "Api::V1::InAppCampaignsController#pause", responses: IN_APP_ERRORS.merge(200 => IN_APP_ONE, 409 => ERROR)
  register "Api::V1::InAppCampaignsController#resume", responses: IN_APP_ERRORS.merge(200 => IN_APP_ONE, 409 => ERROR)
  register "Api::V1::InAppCampaignsController#finish", responses: IN_APP_ERRORS.merge(200 => IN_APP_ONE, 409 => ERROR)
  register "Api::V1::InAppCampaignsController#duplicate", request: strict_object(required: [], properties: { "variant" => STRING }),
                                                          responses: IN_APP_ERRORS.merge(201 => IN_APP_ONE, 409 => ERROR, 422 => ERROR)
  register "Api::V1::InAppCampaignsController#experiment",
           responses: IN_APP_ERRORS.merge(
             200 => strict_object(required: %w[experiment], properties: { "experiment" => EXPERIMENT }),
             422 => ERROR, 503 => strict_object(required: %w[error error_code], properties: { "error" => STRING, "error_code" => STRING })
           )
  IN_APP_COUNTS = { "views" => { "type" => "integer" }, "clicks" => { "type" => "integer" }, "dismissals" => { "type" => "integer" } }.freeze
  IN_APP_REPORT = strict_object(
    required: %w[totals trend platforms buttons eligible_devices answers],
    properties: {
      "totals" => strict_object(required: %w[views clicks dismissals unique_viewers unique_clickers click_rate],
                                properties: IN_APP_COUNTS.merge("unique_viewers" => { "type" => "integer" }, "unique_clickers" => { "type" => "integer" },
                                                                "click_rate" => { "type" => "number" })),
      "trend" => { "type" => "array", "items" => strict_object(required: %w[bucket views clicks dismissals],
                                                               properties: IN_APP_COUNTS.merge("bucket" => STRING)) },
      "platforms" => { "type" => "array", "items" => strict_object(required: %w[platform views clicks dismissals],
                                                                   properties: IN_APP_COUNTS.merge("platform" => STRING)) },
      "buttons" => { "type" => "array", "items" => strict_object(required: %w[button_id clicks],
                                                                 properties: { "button_id" => STRING_OR_NULL, "clicks" => { "type" => "integer" } }) },
      "eligible_devices" => { "type" => %w[integer null] },
      "answers" => { "oneOf" => [{ "type" => "null" }, strict_object(
        required: %w[type count score values],
        properties: {
          "type" => STRING, "count" => { "type" => "integer" }, "score" => { "type" => %w[number null] },
          "values" => { "type" => "array", "items" => strict_object(required: %w[value label count comments],
                                                                    properties: { "value" => { "type" => %w[integer string] }, "label" => STRING,
                                                                                  "count" => { "type" => "integer" },
                                                                                  "comments" => { "type" => "integer" } }) }
        }
      )] }
    }
  )
  register "Api::V1::InAppCampaignsController#report",
           responses: IN_APP_ERRORS.merge(200 => strict_object(required: %w[report], properties: { "report" => IN_APP_REPORT }),
                                          422 => ERROR, 503 => strict_object(required: %w[error error_code],
                                                                             properties: { "error" => STRING, "error_code" => STRING }))
  IN_APP_ANSWER_ROW = strict_object(
    required: %w[at platform country app_version comment answer label user],
    properties: { "at" => STRING, "platform" => STRING, "country" => STRING, "app_version" => STRING, "comment" => STRING,
                  "answer" => STRING, "label" => STRING, "user" => STRING_OR_NULL }
  )
  IN_APP_COMMENT = strict_object(required: %w[value comment at platform],
                                 properties: { "value" => STRING, "comment" => STRING, "at" => STRING, "platform" => STRING })
  register "Api::V1::InAppCampaignsController#comments",
           responses: IN_APP_ERRORS.merge(
             200 => strict_object(required: %w[comments next_before],
                                  properties: { "comments" => { "type" => "array", "items" => IN_APP_COMMENT }, "next_before" => STRING_OR_NULL }),
             422 => ERROR, 503 => strict_object(required: %w[error error_code], properties: { "error" => STRING, "error_code" => STRING })
           )
  register "Api::V1::InAppCampaignsController#answers",
           responses: IN_APP_ERRORS.merge(
             200 => strict_object(required: %w[answers],
                                  properties: { "answers" => strict_object(required: %w[type truncated rows],
                                                                           properties: { "type" => STRING, "truncated" => BOOL,
                                                                                         "rows" => { "type" => "array", "items" => IN_APP_ANSWER_ROW } }) }),
             422 => ERROR, 503 => strict_object(required: %w[error error_code], properties: { "error" => STRING, "error_code" => STRING })
           )
  register "Api::V1::InAppCampaignsController#update_audience", responses: IN_APP_ERRORS.merge(202 => IN_APP_ONE, 409 => ERROR, 422 => ERROR)
  register "Api::V1::InAppCampaignsController#test",
           request: strict_object(required: [], properties: { "identifier" => STRING }),
           responses: IN_APP_ERRORS.merge(202 => strict_object(required: %w[devices], properties: { "devices" => { "type" => "integer" } }),
                                          422 => ERROR)
  register "Api::V1::InAppCampaignsController#upload_image",
           request: strict_object(required: [], properties: { "image" => JSON_VALUE }),
           responses: IN_APP_ERRORS.merge(200 => IN_APP_ONE, 409 => ERROR, 422 => ERROR)
  register "Api::V1::InAppCampaignsController#remove_image", responses: IN_APP_ERRORS.merge(200 => IN_APP_ONE, 409 => ERROR, 422 => ERROR)
  IN_APP_MEDIA_ITEM = strict_object(required: %w[id url type bytes used],
                                    properties: { "id" => STRING, "url" => STRING, "type" => STRING, "bytes" => { "type" => "integer" },
                                                  "used" => BOOL })
  IN_APP_MEDIA_LIST = strict_object(required: %w[media], properties: { "media" => { "type" => "array", "items" => IN_APP_MEDIA_ITEM } })
  register "Api::V1::InAppCampaignsController#media_index", responses: IN_APP_ERRORS.merge(200 => IN_APP_MEDIA_LIST)
  register "Api::V1::InAppCampaignsController#upload_media",
           request: strict_object(required: [], properties: { "file" => JSON_VALUE, "lock_version" => { "type" => %w[integer string] } }),
           responses: IN_APP_ERRORS.merge(201 => strict_object(required: %w[media lock_version],
                                                                properties: { "media" => IN_APP_MEDIA_ITEM, "lock_version" => { "type" => "integer" } }),
                                          409 => ERROR, 422 => ERROR)
  register "Api::V1::InAppCampaignsController#remove_media",
           request: strict_object(required: [], properties: { "lock_version" => { "type" => %w[integer string] } }),
           responses: IN_APP_ERRORS.merge(200 => strict_object(required: %w[message lock_version],
                                                               properties: { "message" => STRING, "lock_version" => { "type" => "integer" } }),
                                          404 => ERROR, 409 => ERROR, 422 => ERROR)
  register "Api::V1::InAppSettingsController#show", responses: IN_APP_ERRORS.merge(200 => IN_APP_SETTINGS)
  register "Api::V1::InAppSettingsController#update",
           request: strict_object(required: [], properties: { "enabled" => BOOL, "session_cap" => { "type" => "integer" },
                                                              "day_cap" => { "type" => "integer" }, "control_group" => { "type" => "integer" },
                                                              "push_daily_cap" => { "type" => %w[integer null] } }),
           responses: IN_APP_ERRORS.merge(200 => IN_APP_SETTINGS, 422 => ERROR)
  register "Public::InAppPreviewController#show",
           responses: { 200 => unchecked("a static HTML page, not JSON") }
end
