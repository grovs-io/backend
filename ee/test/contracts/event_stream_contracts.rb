require_relative "../../../test/contracts/external_api_contracts"

module ApiContracts
  EVENT_DESTINATION_SETTINGS = strict_object(
    required: [],
    properties: { "url" => STRING, "bucket" => STRING, "region" => STRING, "prefix" => STRING, "endpoint" => STRING,
                  "force_path_style" => { "type" => %w[boolean string] } }
  )
  EVENT_DESTINATION_CREDENTIALS = strict_object(
    required: [],
    properties: { "headers" => ANY_OBJECT, "access_key_id" => STRING, "secret_access_key" => STRING }
  )
  EVENT_DESTINATION = strict_object(
    required: %w[id name kind status paused_reason event_types batch_size concurrency include_ip settings has_credentials
                 consecutive_failures last_error last_attempt_at last_delivered_at delivered_count backoff_until failing_since
                 events_cursor_at purchases_cursor_at lag_seconds created_at updated_at],
    properties: {
      "id" => STRING, "name" => STRING, "kind" => { "type" => "string", "enum" => EventDestination::KINDS },
      "status" => { "type" => "string", "enum" => EventDestination::STATUSES }, "paused_reason" => STRING_OR_NULL,
      "event_types" => { "type" => "array", "items" => STRING }, "batch_size" => { "type" => "integer" },
      "concurrency" => { "type" => "integer" }, "include_ip" => { "type" => "boolean" }, "settings" => EVENT_DESTINATION_SETTINGS,
      "has_credentials" => { "type" => "boolean" }, "consecutive_failures" => { "type" => "integer" }, "last_error" => STRING_OR_NULL,
      "last_attempt_at" => STRING_OR_NULL, "last_delivered_at" => STRING_OR_NULL, "delivered_count" => { "type" => "integer" },
      "backoff_until" => STRING_OR_NULL, "failing_since" => STRING_OR_NULL, "events_cursor_at" => STRING_OR_NULL,
      "purchases_cursor_at" => STRING_OR_NULL, "lag_seconds" => INTEGER_OR_NULL, "created_at" => STRING, "updated_at" => STRING
    }
  )
  EVENT_DESTINATION_ONE = strict_object(required: %w[event_destination], properties: { "event_destination" => EVENT_DESTINATION })
  EVENT_DESTINATION_REQUEST = strict_object(
    required: [],
    properties: { "name" => STRING, "kind" => STRING, "settings" => EVENT_DESTINATION_SETTINGS, "credentials" => EVENT_DESTINATION_CREDENTIALS,
                  "event_types" => { "type" => "array", "items" => STRING }, "batch_size" => { "type" => %w[integer string] },
                  "concurrency" => { "type" => %w[integer string] }, "include_ip" => { "type" => %w[boolean string] } }
  )
  EVENT_DESTINATION_ERRORS = { 402 => ERROR, 403 => ERROR, 404 => ERROR, 401 => AUTH_ERROR }.freeze
  EVENT_EXPORT_RETENTION_ERROR = strict_object(required: %w[error error_code], properties: { "error" => STRING, "error_code" => STRING })

  register "Api::V1::EventDestinationsController#index",
           responses: EVENT_DESTINATION_ERRORS.merge(
             200 => strict_object(required: %w[event_destinations], properties: { "event_destinations" => { "type" => "array", "items" => EVENT_DESTINATION } })
           )
  register "Api::V1::EventDestinationsController#create", request: EVENT_DESTINATION_REQUEST,
           responses: EVENT_DESTINATION_ERRORS.merge(
             201 => strict_object(required: %w[event_destination signing_secret],
                                  properties: { "event_destination" => EVENT_DESTINATION, "signing_secret" => STRING_OR_NULL }),
             422 => ERROR
           )
  register "Api::V1::EventDestinationsController#update", request: EVENT_DESTINATION_REQUEST,
           responses: EVENT_DESTINATION_ERRORS.merge(200 => EVENT_DESTINATION_ONE, 422 => ERROR)
  register "Api::V1::EventDestinationsController#destroy", responses: EVENT_DESTINATION_ERRORS.merge(200 => MESSAGE)
  register "Api::V1::EventDestinationsController#pause", responses: EVENT_DESTINATION_ERRORS.merge(200 => EVENT_DESTINATION_ONE)
  register "Api::V1::EventDestinationsController#resume", responses: EVENT_DESTINATION_ERRORS.merge(200 => EVENT_DESTINATION_ONE)
  register "Api::V1::EventDestinationsController#rewind", request: strict_object(required: %w[to], properties: { "to" => STRING }),
           responses: EVENT_DESTINATION_ERRORS.merge(200 => EVENT_DESTINATION_ONE, 400 => ERROR, 422 => ERROR)
  register "Api::V1::EventDestinationsController#test", responses: EVENT_DESTINATION_ERRORS.merge(200 => MESSAGE, 424 => ERROR, 503 => ERROR)
  register "Api::V1::EventDestinationsController#create_export",
           request: strict_object(required: %w[start_date end_date], properties: { "start_date" => STRING, "end_date" => STRING, "destination_id" => STRING }),
           responses: EVENT_DESTINATION_ERRORS.merge(202 => MESSAGE, 400 => ERROR, 422 => { "oneOf" => [ERROR, EVENT_EXPORT_RETENTION_ERROR] })
end

module ApiContracts
  EVENT_STREAM_TOKEN = strict_object(
    required: %w[id name created_at last_used_at created_by_email],
    properties: { "id" => STRING, "name" => STRING, "created_at" => STRING, "last_used_at" => STRING_OR_NULL, "created_by_email" => STRING_OR_NULL }
  )
  EVENT_STREAM_TOKEN_ERRORS = { 402 => ERROR, 403 => ERROR, 404 => ERROR, 401 => AUTH_ERROR }.freeze

  register "Api::V1::EventStreamController#index",
           request: strict_object(required: [], properties: { "after" => STRING, "limit" => { "type" => %w[integer string] },
                                                              "event_types" => { "type" => "array", "items" => STRING } }),
           responses: { 200 => strict_object(required: %w[schema_version events next_after],
                                             properties: { "schema_version" => { "type" => "integer" },
                                                           "events" => { "type" => "array", "items" => ANY_OBJECT }, "next_after" => STRING }),
                        400 => ERROR, 401 => AUTH_ERROR, 402 => ERROR, 403 => ERROR }
  register "Api::V1::EventStreamController#tokens",
           responses: EVENT_STREAM_TOKEN_ERRORS.merge(
             200 => strict_object(required: %w[event_stream_tokens],
                                  properties: { "event_stream_tokens" => { "type" => "array", "items" => EVENT_STREAM_TOKEN } })
           )
  register "Api::V1::EventStreamController#create_token", request: strict_object(required: %w[name], properties: { "name" => STRING }),
           responses: EVENT_STREAM_TOKEN_ERRORS.merge(
             201 => strict_object(required: %w[event_stream_token token], properties: { "event_stream_token" => EVENT_STREAM_TOKEN, "token" => STRING }),
             422 => ERROR
           )
  register "Api::V1::EventStreamController#destroy_token", responses: EVENT_STREAM_TOKEN_ERRORS.merge(200 => MESSAGE)
end
