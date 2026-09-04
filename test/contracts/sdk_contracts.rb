require_relative "external_api_contracts"

# Strict contracts for SDK and server-SDK endpoints. Request schemas model the
# controller's accepted params, and response schemas lock the public JSON
# envelopes emitted by the SDK controllers and serializers.
module ApiContracts
  SDK_ATTRIBUTES = { "type" => %w[object string null] }.freeze

  SDK_REQUEST = {
    "type" => "object",
    "additionalProperties" => true
  }.freeze

  AUTHENTICATE_REQUEST = strict_object(
    required: %w[vendor_id user_agent app_version],
    properties: {
      "vendor_id" => STRING,
      "user_agent" => STRING,
      "app_version" => STRING,
      "device" => STRING_OR_NULL, # what the mobile SDKs actually send; `model` is the alias
      "model" => STRING_OR_NULL,
      "build" => STRING_OR_NULL,
      "screen_width" => { "type" => %w[integer string null] },
      "screen_height" => { "type" => %w[integer string null] },
      "timezone" => STRING_OR_NULL,
      "webgl_vendor" => STRING_OR_NULL,
      "webgl_renderer" => STRING_OR_NULL,
      "language" => STRING_OR_NULL
    }
  )

  DEVICE_FOR_VENDOR_REQUEST = strict_object(
    required: [],
    properties: {
      "vendor_id" => STRING_OR_NULL
    }
  )

  # add_event accepts link-resolution params (link/path/created_at/engagement_time)
  # AND tolerates enrichment params (event_name/session_id/tags/properties) — clients
  # may send them; the controller uses or ignores each. Union of both branches.
  EVENT_REQUEST = strict_object(
    required: %w[event],
    properties: {
      "event" => STRING,
      "path" => STRING_OR_NULL,
      "link" => STRING_OR_NULL,
      "created_at" => STRING_OR_NULL,
      "engagement_time" => { "type" => %w[integer string null] },
      "event_name" => STRING_OR_NULL,
      "session_id" => STRING_OR_NULL,
      "tags" => ARRAY_OR_NULL,
      "properties" => JSON_VALUE
    }
  )

  # add_custom_event — properties is a free-form bag. event_name is NOT contract-
  # required: the controller validates its presence and returns 400 (negative tests
  # send no event_name to exercise that path), so requiring it here would pre-empt them.
  CUSTOM_EVENT_REQUEST = strict_object(
    required: [],
    properties: {
      "event_name" => STRING_OR_NULL,
      "path" => STRING_OR_NULL,
      "link" => STRING_OR_NULL,
      "session_id" => STRING_OR_NULL,
      "engagement_time" => { "type" => %w[integer string null] },
      "tags" => ARRAY_OR_NULL,
      "properties" => JSON_VALUE
    }
  )

  # add_batch — events is an array of arbitrary per-event payloads. Type is
  # array|string|null so the controller's own "must be an array" 400 path (which
  # negative tests exercise) isn't pre-empted by request-contract validation.
  BATCH_EVENTS_REQUEST = strict_object(
    required: %w[events],
    properties: { "events" => { "type" => %w[array string null] } }
  )
  BATCH_EVENTS_RESPONSE = strict_object(
    required: %w[accepted rejected errors],
    properties: {
      "accepted" => { "type" => "integer" },
      "rejected" => { "type" => "integer" },
      "errors" => ARRAY
    }
  )

  # screen_aliases#create — array of {identifier, alias}; returns saved count.
  SCREEN_ALIASES_REQUEST = strict_object(
    required: %w[screen_aliases],
    properties: { "screen_aliases" => { "type" => %w[array string null] } }
  )
  SCREEN_ALIASES_RESPONSE = strict_object(
    required: %w[saved],
    properties: { "saved" => { "type" => "integer" } }
  )

  USER_AGENT_REQUEST = strict_object(
    required: %w[user_agent],
    properties: {
      "user_agent" => STRING,
      "session_id" => STRING_OR_NULL
    }
  )

  LINK_LOOKUP_REQUEST = strict_object(
    required: %w[path],
    properties: {
      "path" => STRING
    }
  )

  LINK_URL_REQUEST = strict_object(
    required: %w[url user_agent],
    properties: {
      "url" => STRING,
      "user_agent" => STRING,
      "session_id" => STRING_OR_NULL
    }
  )

  LINK_PATH_REQUEST = strict_object(
    required: %w[path user_agent],
    properties: {
      "path" => STRING,
      "user_agent" => STRING,
      "session_id" => STRING_OR_NULL
    }
  )

  SDK_LINK_CREATE_REQUEST = strict_object(
    required: [],
    properties: {
      "title" => STRING_OR_NULL,
      "subtitle" => STRING_OR_NULL,
      "data" => JSON_VALUE,
      "tags" => ARRAY_OR_NULL,
      "image_url" => STRING_OR_NULL,
      "image" => JSON_VALUE,
      "show_preview" => BOOL_OR_NULL,
      "show_preview_ios" => BOOL_OR_NULL,
      "show_preview_android" => BOOL_OR_NULL,
      "copy_to_clipboard_ios" => BOOL_OR_NULL,
      "copy_to_clipboard_android" => BOOL_OR_NULL,
      "tracking_campaign" => STRING_OR_NULL,
      "tracking_medium" => STRING_OR_NULL,
      "tracking_source" => STRING_OR_NULL,
      "ios_custom_redirect" => JSON_VALUE,
      "android_custom_redirect" => JSON_VALUE,
      "desktop_custom_redirect" => JSON_VALUE,
      "user_agent" => STRING_OR_NULL
    }
  )

  SERVER_LINK_CREATE_REQUEST = strict_object(
    required: [],
    properties: SDK_LINK_CREATE_REQUEST.fetch("properties").except("user_agent")
  )

  SET_VISITOR_ATTRIBUTES_REQUEST = strict_object(
    required: [],
    properties: {
      "sdk_identifier" => STRING_OR_NULL,
      "sdk_attributes" => OBJECT_OR_NULL,
      "push_token" => STRING_OR_NULL
    }
  )

  NOTIFICATIONS_PAGE_REQUEST = strict_object(
    required: %w[page],
    properties: {
      "page" => { "type" => %w[integer string] }
    }
  )

  NOTIFICATION_ID_REQUEST = strict_object(
    required: %w[id],
    properties: {
      "id" => { "type" => %w[integer string] }
    }
  )

  LINK_DATA_RESPONSE = strict_object(
    required: %w[data link tracking],
    properties: {
      "data" => JSON_VALUE,
      "link" => STRING_OR_NULL,
      "tracking" => {
        "type" => %w[object null],
        "additionalProperties" => false,
        "required" => %w[source campaign medium],
        "properties" => {
          "source" => STRING_OR_NULL,
          "campaign" => STRING_OR_NULL,
          "medium" => STRING_OR_NULL
        }
      }
    }
  )

  LINK_PATH_RESPONSE = strict_object(
    required: %w[link],
    properties: {
      "link" => STRING
    }
  )

  SDK_AUTH_RESPONSE = strict_object(
    required: %w[linksquared uri_scheme sdk_identifier sdk_attributes push_token],
    properties: {
      "linksquared" => STRING,
      "uri_scheme" => STRING_OR_NULL,
      "sdk_identifier" => STRING_OR_NULL,
      "sdk_attributes" => SDK_ATTRIBUTES,
      "push_token" => STRING_OR_NULL
    }
  )

  LAST_SEEN_RESPONSE = strict_object(
    required: %w[last_seen],
    properties: {
      "last_seen" => STRING_OR_NULL
    }
  )

  CUSTOM_REDIRECT_RESPONSE = {
    "type" => %w[object null],
    "additionalProperties" => false,
    "required" => %w[url open_app_if_installed],
    "properties" => {
      "url" => STRING_OR_NULL,
      "open_app_if_installed" => BOOL
    }
  }.freeze

  LINK_RESPONSE = strict_object(
    required: %w[
      id name path title subtitle active sdk_generated data tags updated_at
      show_preview_ios show_preview_android copy_to_clipboard_ios copy_to_clipboard_android
      ads_platform generated_from_platform
      tracking_source tracking_medium tracking_campaign visitor_id campaign_id
      image access_path ios_custom_redirect android_custom_redirect desktop_custom_redirect
    ],
    properties: {
      "id" => ID,
      "name" => STRING_OR_NULL,
      "path" => STRING,
      "title" => STRING_OR_NULL,
      "subtitle" => STRING_OR_NULL,
      "active" => BOOL,
      "sdk_generated" => BOOL,
      "data" => JSON_VALUE,
      "tags" => ARRAY_OR_NULL,
      "updated_at" => STRING,
      "show_preview_ios" => BOOLEAN_OR_NULL,
      "show_preview_android" => BOOLEAN_OR_NULL,
      "copy_to_clipboard_ios" => BOOLEAN_OR_NULL,
      "copy_to_clipboard_android" => BOOLEAN_OR_NULL,
      "ads_platform" => STRING_OR_NULL,
      "generated_from_platform" => STRING_OR_NULL,
      "tracking_source" => STRING_OR_NULL,
      "tracking_medium" => STRING_OR_NULL,
      "tracking_campaign" => STRING_OR_NULL,
      "visitor_id" => INTEGER_OR_NULL,
      "campaign_id" => INTEGER_OR_NULL,
      "image" => JSON_VALUE,
      "access_path" => STRING,
      "ios_custom_redirect" => CUSTOM_REDIRECT_RESPONSE,
      "android_custom_redirect" => CUSTOM_REDIRECT_RESPONSE,
      "desktop_custom_redirect" => CUSTOM_REDIRECT_RESPONSE
    }
  )

  VISITOR_RESPONSE = strict_object(
    required: %w[
      id uuid sdk_identifier sdk_attributes inviter_id web_visitor created_at
      updated_at inviter invited
    ],
    properties: {
      "id" => ID,
      "uuid" => STRING,
      "sdk_identifier" => STRING_OR_NULL,
      "sdk_attributes" => SDK_ATTRIBUTES,
      "inviter_id" => INTEGER_OR_NULL,
      "web_visitor" => BOOL,
      "created_at" => STRING,
      "updated_at" => STRING,
      "inviter" => STRING_OR_NULL,
      "invited" => ARRAY
    }
  )

  VISITOR_ENVELOPE = strict_object(
    required: %w[visitor],
    properties: {
      "visitor" => VISITOR_RESPONSE
    }
  )

  NOTIFICATION_MESSAGE_RESPONSE = strict_object(
    required: %w[id read access_url updated_at title subtitle auto_display],
    properties: {
      "id" => ID,
      "read" => BOOL,
      "access_url" => STRING,
      "updated_at" => STRING,
      "title" => STRING_OR_NULL,
      "subtitle" => STRING_OR_NULL,
      "auto_display" => BOOL
    }
  )

  NOTIFICATIONS_ENVELOPE = strict_object(
    required: %w[notifications],
    properties: {
      "notifications" => {
        "type" => "array",
        "items" => NOTIFICATION_MESSAGE_RESPONSE
      }
    }
  )

  UNREAD_COUNT_RESPONSE = strict_object(
    required: %w[number_of_unread_notifications],
    properties: {
      "number_of_unread_notifications" => { "type" => "integer" }
    }
  )

  SERVER_LINK_DETAILS_RESPONSE = strict_object(
    required: %w[link],
    properties: {
      "link" => LINK_RESPONSE
    }
  )

  SLIM_LINK_RESPONSE = strict_object(
    required: %w[
      id name path title subtitle active sdk_generated data tags updated_at
      show_preview_ios show_preview_android copy_to_clipboard_ios copy_to_clipboard_android
      ads_platform generated_from_platform
      tracking_source tracking_medium tracking_campaign visitor_id campaign_id
    ],
    properties: LINK_RESPONSE.fetch("properties").slice(
      "id", "name", "path", "title", "subtitle", "active", "sdk_generated",
      "data", "tags", "updated_at", "show_preview_ios", "show_preview_android",
      "copy_to_clipboard_ios", "copy_to_clipboard_android",
      "ads_platform", "generated_from_platform", "tracking_source",
      "tracking_medium", "tracking_campaign", "visitor_id", "campaign_id"
    )
  )

  METRICS_RESPONSE = strict_object(
    required: %w[metrics],
    properties: {
      "metrics" => SLIM_LINK_RESPONSE.merge("type" => %w[object null])
    }
  )

  METRICS_ARRAY_RESPONSE = {
    "type" => "array",
    "items" => SLIM_LINK_RESPONSE
  }.freeze

  SDK_PAYMENT_EVENT_RESPONSE = {
    "type" => "object",
    "additionalProperties" => true
  }.freeze

  SDK_AUTH_FAILURES = {
    403 => ERROR,
    422 => ERROR
  }.freeze

  SERVER_SDK_AUTH_FAILURES = {
    400 => ERROR,
    403 => ERROR
  }.freeze

  register "Api::V1::Sdk::AuthController#authenticate",
           request: AUTHENTICATE_REQUEST,
           responses: { 200 => SDK_AUTH_RESPONSE, **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::AuthController#device_for_vendor",
           request: DEVICE_FOR_VENDOR_REQUEST,
           responses: { 200 => LAST_SEEN_RESPONSE, **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::EventsController#add_event",
           request: EVENT_REQUEST,
           responses: { 200 => MESSAGE, **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::EventsController#add_custom_event",
           request: CUSTOM_EVENT_REQUEST,
           responses: { 200 => MESSAGE, 400 => ERROR, **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::EventsController#add_batch",
           request: BATCH_EVENTS_REQUEST,
           responses: { 200 => BATCH_EVENTS_RESPONSE, 400 => ERROR, **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::ScreenAliasesController#create",
           request: SCREEN_ALIASES_REQUEST,
           responses: { 200 => SCREEN_ALIASES_RESPONSE, 400 => ERROR, **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::LinksController#create_link",
           request: SDK_LINK_CREATE_REQUEST,
           responses: { 200 => LINK_PATH_RESPONSE, **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::LinksController#data_for_device_details",
           request: USER_AGENT_REQUEST,
           responses: { 200 => LINK_DATA_RESPONSE, **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::LinksController#data_for_device_details_and_path",
           request: LINK_PATH_REQUEST,
           responses: { 200 => LINK_DATA_RESPONSE, **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::LinksController#data_for_device_details_and_url",
           request: LINK_URL_REQUEST,
           responses: { 200 => LINK_DATA_RESPONSE, **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::LinksController#link_details",
           request: LINK_LOOKUP_REQUEST,
           responses: { 200 => LINK_RESPONSE.merge("type" => %w[object null]), **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::LinksController#clipboard_status",
           request: NO_PARAMS,
           responses: { 200 => strict_object(required: %w[clipboard_active], properties: { "clipboard_active" => BOOL }), **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::NotificationsController#mark_notification_as_read",
           request: NOTIFICATION_ID_REQUEST,
           responses: { 200 => MESSAGE, 404 => ERROR, **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::NotificationsController#notifications_for_device",
           request: NOTIFICATIONS_PAGE_REQUEST,
           responses: { 200 => NOTIFICATIONS_ENVELOPE, **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::NotificationsController#notifications_to_display_automatically",
           request: NO_PARAMS,
           responses: { 200 => NOTIFICATIONS_ENVELOPE, **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::NotificationsController#number_of_unread_notifications",
           request: NO_PARAMS,
           responses: { 200 => UNREAD_COUNT_RESPONSE, **SDK_AUTH_FAILURES }

  if ENV.fetch("GROVS_EE", "false") == "true"
    register "Api::V1::Sdk::PaymentsController#add_payment_event",
             request: SDK_REQUEST,
             responses: { 200 => SDK_PAYMENT_EVENT_RESPONSE, **SDK_AUTH_FAILURES }
  end

  register "Api::V1::Sdk::VisitorsController#set_visitor_attributes",
           request: SET_VISITOR_ATTRIBUTES_REQUEST,
           responses: { 200 => VISITOR_ENVELOPE, **SDK_AUTH_FAILURES }

  register "Api::V1::Sdk::VisitorsController#visitor_attributes",
           request: NO_PARAMS,
           responses: { 200 => VISITOR_ENVELOPE, **SDK_AUTH_FAILURES }

  register "Api::V1::ServerSdkController#generate_link",
           request: SERVER_LINK_CREATE_REQUEST,
           responses: { 200 => LINK_PATH_RESPONSE, **SERVER_SDK_AUTH_FAILURES }

  register "Api::V1::ServerSdkController#link_details",
           request: NO_PARAMS,
           responses: { 200 => SERVER_LINK_DETAILS_RESPONSE, 404 => ERROR, **SERVER_SDK_AUTH_FAILURES }

  register "Api::V1::ServerSdkController#metrics_for_link",
           request: NO_PARAMS,
           responses: { 200 => METRICS_RESPONSE, 404 => ERROR, **SERVER_SDK_AUTH_FAILURES }

  register "Api::V1::ServerSdkController#metrics_for_project",
           request: NO_PARAMS,
           responses: { 200 => METRICS_ARRAY_RESPONSE, **SERVER_SDK_AUTH_FAILURES }
end
