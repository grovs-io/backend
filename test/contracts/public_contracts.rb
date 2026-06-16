require_relative "external_api_contracts"

# First-pass contracts for public endpoints. Most public routes return HTML,
# redirects, empty bodies, or well-known files, so response bodies stay relaxed.
module ApiContracts
  REDIRECT_OR_HTML = NON_JSON_RESPONSE
  EMPTY_BODY = NON_JSON_RESPONSE

  # Strict query schema for native public-click endpoints. Native URLs are issued by Grovs
  # (with hashid slugs); customers don't append arbitrary query params to them, so we keep
  # the original additionalProperties: false contract here as a real guardrail.
  PUBLIC_QUERY_REQUEST = strict_object(
    required: [],
    properties: {
      "url" => STRING_OR_NULL,
      "go_to_fallback" => BOOL_OR_NULL,
      "grovs_redirect" => STRING_OR_NULL
    }
  )

  # Permissive variant for the open_app_link route. That endpoint receives traffic on
  # MIGRATED hosts as well as native Grovs hosts; migration clicks carry arbitrary query
  # strings (UTMs, referral codes, attacker-controlled params) which must pass through to
  # MigrationResolver and be appended to the 301 target. Allow additional properties here,
  # but keep the strict schema on every other public route.
  PUBLIC_OPEN_LINK_REQUEST = {
    "type" => "object",
    "additionalProperties" => true,
    "required" => [],
    "properties" => {
      "url" => STRING_OR_NULL,
      "go_to_fallback" => BOOL_OR_NULL,
      "grovs_redirect" => STRING_OR_NULL
    }
  }.freeze

  DEVICE_DATA_REQUEST = strict_object(
    required: [],
    properties: {
      "screen_width" => { "type" => %w[integer string null] },
      "screen_height" => { "type" => %w[integer string null] },
      "timezone" => STRING_OR_NULL,
      "webgl_vendor" => STRING_OR_NULL,
      "webgl_renderer" => STRING_OR_NULL,
      "language" => STRING_OR_NULL,
      "device_datum" => {
        "type" => "object",
        "additionalProperties" => false,
        "properties" => {
          "screen_width" => { "type" => %w[integer string null] },
          "screen_height" => { "type" => %w[integer string null] },
          "timezone" => STRING_OR_NULL,
          "webgl_vendor" => STRING_OR_NULL,
          "webgl_renderer" => STRING_OR_NULL,
          "language" => STRING_OR_NULL
        }
      }
    }
  )

  PUBLIC_LINK_REQUEST = strict_object(
    required: [],
    properties: {
      "title" => STRING_OR_NULL,
      "subtitle" => STRING_OR_NULL,
      "data" => JSON_VALUE,
      "tags" => ARRAY_OR_NULL,
      "image_url" => STRING_OR_NULL,
      "image" => JSON_VALUE,
      "ios_phone" => STRING_OR_NULL,
      "ios_tablet" => STRING_OR_NULL,
      "android_phone" => STRING_OR_NULL,
      "android_tablet" => STRING_OR_NULL,
      "desktop" => STRING_OR_NULL,
      "desktop_linux" => STRING_OR_NULL,
      "desktop_mac" => STRING_OR_NULL,
      "desktop_windows" => STRING_OR_NULL,
      "ios_redirect_url" => STRING_OR_NULL,
      "android_redirect_url" => STRING_OR_NULL,
      "desktop_redirect_url" => STRING_OR_NULL,
      "tracking_campaign" => STRING_OR_NULL,
      "tracking_medium" => STRING_OR_NULL,
      "tracking_source" => STRING_OR_NULL,
      "user_agent" => STRING_OR_NULL
    }
  )

  # 301 is added by the migrate-from-competitors feature — old-host clicks issue a 301 to
  # the materialized Link on the project's primary domain (see migrations_contracts.rb).
  # This endpoint uses the permissive PUBLIC_OPEN_LINK_REQUEST because migration traffic
  # carries arbitrary query strings; every other public endpoint stays on the strict schema.
  register "Public::LinksController#open_app_link",
           request: PUBLIC_OPEN_LINK_REQUEST,
           responses: {
             200 => REDIRECT_OR_HTML,
             301 => REDIRECT_OR_HTML,
             302 => REDIRECT_OR_HTML
           }

  register "Public::LinksController#make_redirect",
           request: PUBLIC_QUERY_REQUEST,
           responses: { 200 => REDIRECT_OR_HTML, 302 => REDIRECT_OR_HTML }

  register "Public::MarketingMessagesController#open_marketing_message",
           request: NO_PARAMS,
           responses: { 200 => REDIRECT_OR_HTML }

  register "Public::VerificationController#generate_ios_file",
           request: NO_PARAMS,
           responses: { 200 => NON_JSON_RESPONSE, 404 => NON_JSON_RESPONSE }

  register "Public::VerificationController#generate_android_file",
           request: NO_PARAMS,
           responses: { 200 => NON_JSON_RESPONSE, 404 => NON_JSON_RESPONSE }

  register "Public::DeviceDataController#store_device_data",
           request: DEVICE_DATA_REQUEST,
           responses: { 200 => EMPTY_BODY, 204 => EMPTY_BODY }

  register "Public::PublicLinkController#create",
           request: PUBLIC_LINK_REQUEST,
           responses: { 200 => NON_JSON_RESPONSE, 201 => NON_JSON_RESPONSE, 400 => NON_JSON_RESPONSE, 404 => NON_JSON_RESPONSE, 422 => NON_JSON_RESPONSE }

  register "Public::PublicLinkController#get_link",
           request: NO_PARAMS,
           responses: { 200 => NON_JSON_RESPONSE, 404 => NON_JSON_RESPONSE }
end
