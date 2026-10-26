require_relative "../../../test/contracts/external_api_contracts"

module ApiContracts
  SEGMENT_SIZE = strict_object(
    required: %w[date persons devices],
    properties: { "date" => STRING, "persons" => { "type" => "integer" }, "devices" => { "type" => "integer" } }
  )
  SEGMENT = strict_object(
    required: %w[id name description definition definition_hash archived has_identifier_list identifier_list size created_at updated_at],
    properties: {
      "id" => STRING, "name" => STRING, "description" => STRING_OR_NULL, "definition" => ANY_OBJECT,
      "definition_hash" => STRING, "archived" => { "type" => "boolean" }, "has_identifier_list" => { "type" => "boolean" },
      "size" => { "anyOf" => [SEGMENT_SIZE, { "type" => "null" }] },
      "identifier_list" => { "anyOf" => [strict_object(required: %w[count updated_at],
                                                       properties: { "count" => { "type" => %w[integer null] }, "updated_at" => STRING_OR_NULL }),
                                         { "type" => "null" }] },
      "created_at" => STRING, "updated_at" => STRING
    }
  )
  SEGMENT_ONE = strict_object(required: %w[segment], properties: { "segment" => SEGMENT })
  # JSON_VALUE: a non-object definition must reach the controller's own 422, not the schema.
  SEGMENT_REQUEST = strict_object(
    required: [],
    properties: { "name" => STRING, "description" => STRING_OR_NULL, "definition" => JSON_VALUE,
                  "archived" => { "type" => %w[boolean string] } }
  )
  SEGMENT_ESTIMATE = strict_object(
    required: %w[persons devices approximate incomplete],
    properties: { "persons" => { "type" => "integer" }, "devices" => { "type" => "integer" },
                  "approximate" => { "type" => "boolean" }, "incomplete" => { "type" => "boolean" } }
  )
  SEGMENT_CODED_ERROR = strict_object(required: %w[error error_code], properties: { "error" => STRING, "error_code" => STRING })
  SEGMENT_ERRORS = { 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }.freeze
  SEGMENT_RESULT_ERRORS = SEGMENT_ERRORS.merge(410 => SEGMENT_CODED_ERROR, 422 => { "anyOf" => [ERROR, SEGMENT_CODED_ERROR] },
                                               429 => SEGMENT_CODED_ERROR, 503 => SEGMENT_CODED_ERROR)
  SEGMENT_COUNT = strict_object(
    required: %w[persons devices incomplete result_id],
    properties: { "persons" => { "type" => "integer" }, "devices" => { "type" => "integer" },
                  "incomplete" => { "type" => "boolean" }, "result_id" => STRING }
  )
  SEGMENT_USER = strict_object(required: VISITOR_SLIM_PROPERTIES.keys + %w[person_key],
                               properties: VISITOR_SLIM_PROPERTIES.merge("person_key" => STRING))
  SEGMENT_USERS = strict_object(
    required: %w[users next_cursor result_id persons devices incomplete],
    properties: { "users" => { "type" => "array", "items" => SEGMENT_USER }, "next_cursor" => STRING_OR_NULL,
                  "result_id" => STRING, "persons" => { "type" => "integer" }, "devices" => { "type" => "integer" },
                  "incomplete" => { "type" => "boolean" } }
  )

  register "Api::V1::SegmentsController#index",
           responses: SEGMENT_ERRORS.merge(
             200 => strict_object(required: %w[segments truncated],
                                   properties: { "segments" => { "type" => "array", "items" => SEGMENT },
                                                 "truncated" => { "type" => "boolean" } })
           )
  register "Api::V1::SegmentsController#show", responses: SEGMENT_ERRORS.merge(200 => SEGMENT_ONE)
  SEGMENT_SIZE_HISTORY_POINT = strict_object(
    required: %w[date persons devices incomplete],
    properties: { "date" => STRING, "persons" => { "type" => "integer" }, "devices" => { "type" => "integer" },
                  "incomplete" => { "type" => "boolean" } }
  )
  register "Api::V1::SegmentsController#size_history",
           responses: SEGMENT_ERRORS.merge(
             200 => strict_object(required: %w[size_history],
                                   properties: { "size_history" => { "type" => "array", "items" => SEGMENT_SIZE_HISTORY_POINT } })
           )
  SEGMENT_FIELDS = strict_object(
    required: %w[version limits conditions],
    properties: {
      "version" => { "type" => "integer" },
      "limits" => strict_object(
        required: %w[groups conditions_per_group filters values value_bytes identifier_list],
        properties: { "groups" => { "type" => "integer" }, "conditions_per_group" => { "type" => "integer" },
                      "filters" => { "type" => "integer" }, "values" => { "type" => "integer" },
                      "value_bytes" => { "type" => "integer" }, "identifier_list" => { "type" => "integer" } }
      ),
      "conditions" => { "type" => "array", "items" => ANY_OBJECT }
    }
  )
  register "Api::V1::SegmentsController#fields", responses: SEGMENT_ERRORS.merge(200 => SEGMENT_FIELDS)
  register "Api::V1::SegmentsController#create", request: SEGMENT_REQUEST, responses: SEGMENT_ERRORS.merge(201 => SEGMENT_ONE, 422 => ERROR)
  register "Api::V1::SegmentsController#update", request: SEGMENT_REQUEST, responses: SEGMENT_ERRORS.merge(200 => SEGMENT_ONE, 422 => ERROR)
  register "Api::V1::SegmentsController#destroy",
           responses: SEGMENT_ERRORS.merge(200 => strict_object(required: %w[message], properties: { "message" => STRING }))
  register "Api::V1::SegmentsController#estimate",
           request: strict_object(required: [], properties: { "definition" => ANY_OBJECT, "segment_id" => STRING }),
           responses: SEGMENT_ERRORS.merge(200 => SEGMENT_ESTIMATE, 422 => { "anyOf" => [ERROR, SEGMENT_CODED_ERROR] },
                                           429 => SEGMENT_CODED_ERROR, 503 => SEGMENT_CODED_ERROR)
  register "Api::V1::SegmentsController#count", responses: SEGMENT_RESULT_ERRORS.merge(200 => SEGMENT_COUNT)
  SEGMENT_IDENTIFIER_LIST = strict_object(
    required: %w[segment count],
    properties: { "segment" => SEGMENT, "count" => { "type" => "integer" } }
  )
  # identifiers/file are JSON_VALUE: a bad body or multipart upload reaches the controller, not the schema.
  register "Api::V1::SegmentsController#identifier_list",
           request: strict_object(required: [], properties: { "identifiers" => JSON_VALUE, "file" => JSON_VALUE }),
           responses: SEGMENT_ERRORS.merge(200 => SEGMENT_IDENTIFIER_LIST, 409 => SEGMENT_CODED_ERROR,
                                           422 => ERROR, 503 => SEGMENT_CODED_ERROR)
  register "Api::V1::SegmentsController#identifier_list_preview",
           request: strict_object(required: [], properties: { "q" => STRING }),
           responses: SEGMENT_ERRORS.merge(
             200 => strict_object(required: %w[identifiers more],
                                  properties: { "identifiers" => { "type" => "array", "items" => STRING }, "more" => { "type" => "boolean" } }),
             503 => SEGMENT_CODED_ERROR
           )
  register "Api::V1::SegmentsController#identifier_list_download",
           responses: SEGMENT_ERRORS.merge(200 => NON_JSON_RESPONSE, 503 => SEGMENT_CODED_ERROR)
  SEGMENT_BREAKDOWN_BUCKET = strict_object(
    required: %w[value label persons],
    properties: { "value" => STRING, "label" => STRING, "persons" => { "type" => "integer" } }
  )
  SEGMENT_BREAKDOWN = strict_object(
    required: %w[by total_persons result_id buckets],
    properties: { "by" => STRING, "total_persons" => { "type" => "integer" }, "result_id" => STRING,
                  "buckets" => { "type" => "array", "items" => SEGMENT_BREAKDOWN_BUCKET } }
  )
  register "Api::V1::SegmentsController#breakdown",
           request: strict_object(required: %w[by], properties: { "by" => STRING, "result_id" => STRING }),
           responses: SEGMENT_RESULT_ERRORS.merge(200 => SEGMENT_BREAKDOWN)
  # limit is JSON_VALUE so a junk shape reaches the controller's own 422, not the schema.
  register "Api::V1::SegmentsController#users",
           request: strict_object(required: [], properties: { "cursor" => STRING, "limit" => JSON_VALUE, "q" => STRING, "result_id" => STRING }),
           responses: SEGMENT_RESULT_ERRORS.merge(200 => SEGMENT_USERS)

  SEGMENT_EXPORT = strict_object(
    required: %w[id segment_id status rows definition_hash error download_url created_at updated_at],
    properties: {
      "id" => STRING, "segment_id" => STRING, "status" => STRING, "rows" => INTEGER_OR_NULL,
      "definition_hash" => STRING, "error" => STRING_OR_NULL, "download_url" => STRING_OR_NULL,
      "created_at" => STRING, "updated_at" => STRING
    }
  )
  SEGMENT_EXPORT_ONE = strict_object(required: %w[export], properties: { "export" => SEGMENT_EXPORT })

  register "Api::V1::SegmentsController#export", responses: SEGMENT_ERRORS.merge(202 => SEGMENT_EXPORT_ONE)
  register "Api::V1::SegmentsController#exports",
           responses: SEGMENT_ERRORS.merge(
             200 => strict_object(required: %w[exports], properties: { "exports" => { "type" => "array", "items" => SEGMENT_EXPORT } })
           )
  register "Api::V1::SegmentsController#export_status", responses: SEGMENT_ERRORS.merge(200 => SEGMENT_EXPORT_ONE)
end
