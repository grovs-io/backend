require_relative "external_api_contracts"
require_relative "sdk_contracts"

# Contracts for MCP endpoints. Tool request payloads and a few analytics/search
# result objects stay flexible, but endpoint status codes and top-level JSON
# envelopes are locked so accidental API drift is visible in integration tests.
module ApiContracts # rubocop:disable Metrics/ModuleLength
  MCP_REQUEST = {
    "type" => "object",
    "additionalProperties" => true
  }.freeze

  MCP_NO_PARAMS = NO_PARAMS
  MCP_PROJECT_REQUEST = strict_object(
    required: [],
    properties: {
      "project_id" => STRING
    }
  )
  MCP_DATE_RANGE_REQUEST = strict_object(
    required: [],
    properties: {
      "project_id" => STRING,
      "start_date" => STRING_OR_NULL,
      "end_date" => STRING_OR_NULL,
      "platform" => STRING_OR_NULL
    }
  )
  MCP_LINK_STATS_REQUEST = strict_object(
    required: [],
    properties: MCP_DATE_RANGE_REQUEST.fetch("properties").merge("path" => STRING)
  )
  MCP_TOP_LINKS_REQUEST = strict_object(
    required: [],
    properties: MCP_DATE_RANGE_REQUEST.fetch("properties").merge("limit" => { "type" => %w[integer string null] })
  )
  MCP_CONSENT_REQUEST = strict_object(
    required: [],
    properties: {
      "redirect_uri" => STRING,
      "client_id" => STRING,
      "code_challenge" => STRING,
      "code_challenge_method" => STRING,
      "state" => STRING_OR_NULL,
      "scope" => STRING_OR_NULL
    }
  )
  MCP_USAGE_REQUEST = strict_object(required: [], properties: { "instance_id" => STRING })
  MCP_CAMPAIGN_CREATE_REQUEST = strict_object(
    required: [],
    properties: MCP_PROJECT_REQUEST.fetch("properties").merge("name" => STRING)
  )
  MCP_SEARCH_REQUEST = strict_object(
    required: [],
    properties: MCP_PROJECT_REQUEST.fetch("properties").merge(
      "page" => { "type" => %w[integer string null] },
      "per_page" => { "type" => %w[integer string null] },
      "term" => STRING_OR_NULL,
      "sort_by" => STRING_OR_NULL,
      "ascendent" => BOOL_OR_NULL,
      "start_date" => STRING_OR_NULL,
      "end_date" => STRING_OR_NULL,
      "platform" => STRING_OR_NULL,
      "campaign_id" => ID,
      "archived" => BOOL_OR_NULL
    )
  )
  MCP_REDIRECT_PLATFORM_CONFIG = {
    "type" => "object",
    "additionalProperties" => false,
    "properties" => {
      "variation" => STRING_OR_NULL,
      "fallback_url" => STRING_OR_NULL,
      "appstore" => BOOL_OR_NULL,
      "enabled" => BOOL_OR_NULL
    }
  }.freeze
  MCP_SETUP_REDIRECTS_REQUEST = strict_object(
    required: [],
    properties: MCP_PROJECT_REQUEST.fetch("properties").merge(
      "default_fallback" => STRING_OR_NULL,
      "show_preview_ios" => BOOL_OR_NULL,
      "show_preview_android" => BOOL_OR_NULL,
      "platforms" => {
        "type" => %w[object null],
        "additionalProperties" => MCP_REDIRECT_PLATFORM_CONFIG
      }
    )
  )
  MCP_SDK_PLATFORM_CONFIG = {
    "type" => "object",
    "additionalProperties" => false,
    "properties" => {
      "enabled" => BOOL_OR_NULL,
      "bundle_id" => STRING_OR_NULL,
      "app_prefix" => STRING_OR_NULL,
      "tablet_enabled" => BOOL_OR_NULL,
      "identifier" => STRING_OR_NULL,
      "sha256s" => { "type" => %w[array string null] },
      "url" => STRING_OR_NULL,
      "generated_page" => BOOL_OR_NULL,
      "fallback_url" => STRING_OR_NULL,
      "mac_uri" => STRING_OR_NULL,
      "windows_uri" => STRING_OR_NULL,
      "mac_enabled" => BOOL_OR_NULL,
      "windows_enabled" => BOOL_OR_NULL
    }
  }.freeze
  MCP_SETUP_SDK_REQUEST = strict_object(
    required: [],
    properties: {
      "instance_id" => STRING,
      "platforms" => {
        "type" => "object",
        "additionalProperties" => MCP_SDK_PLATFORM_CONFIG
      }
    }
  )
  MCP_CUSTOM_REDIRECT_VALUE = {
    "oneOf" => [
      STRING,
      strict_object(
        required: [],
        properties: {
          "url" => STRING_OR_NULL,
          "open_app_if_installed" => BOOL_OR_NULL
        }
      )
    ]
  }.freeze
  MCP_LINK_MUTATION_REQUEST = strict_object(
    required: [],
    properties: MCP_PROJECT_REQUEST.fetch("properties").merge(
      "name" => STRING_OR_NULL,
      "title" => STRING_OR_NULL,
      "subtitle" => STRING_OR_NULL,
      "path" => STRING_OR_NULL,
      "image_url" => STRING_OR_NULL,
      "show_preview_ios" => BOOL_OR_NULL,
      "show_preview_android" => BOOL_OR_NULL,
      "ads_platform" => STRING_OR_NULL,
      "tracking_campaign" => STRING_OR_NULL,
      "tracking_medium" => STRING_OR_NULL,
      "tracking_source" => STRING_OR_NULL,
      "tags" => { "type" => %w[array string null] },
      "data" => JSON_VALUE,
      "image" => JSON_VALUE,
      "campaign_id" => ID,
      "hidden" => BOOL_OR_NULL,
      "custom_redirects" => {
        "type" => %w[object null],
        "additionalProperties" => false,
        "properties" => {
          "ios" => MCP_CUSTOM_REDIRECT_VALUE,
          "android" => MCP_CUSTOM_REDIRECT_VALUE,
          "desktop" => MCP_CUSTOM_REDIRECT_VALUE
        }
      }
    )
  )
  MCP_LINK_CREATE_REQUEST = MCP_LINK_MUTATION_REQUEST
  MCP_PROJECT_CREATE_REQUEST = strict_object(required: [], properties: { "name" => STRING })

  def self.mcp_object(required:, properties:)
    strict_object(
      required: required,
      properties: properties.merge("_warning" => STRING_OR_NULL)
    )
  end

  MCP_ERROR = mcp_object(
    required: %w[error],
    properties: {
      "error" => STRING,
      "error_description" => STRING_OR_NULL
    }
  )

  MCP_MESSAGE = mcp_object(
    required: %w[message],
    properties: {
      "message" => STRING
    }
  )

  MCP_AUTH_CODE_RESPONSE = strict_object(
    required: %w[code redirect_uri],
    properties: {
      "code" => STRING,
      "redirect_uri" => STRING,
      "state" => STRING_OR_NULL
    }
  )

  MCP_TOKEN_RESPONSE = strict_object(
    required: %w[id name client_id created_at last_used_at],
    properties: {
      "id" => STRING,
      "name" => STRING_OR_NULL,
      "client_id" => STRING_OR_NULL,
      "created_at" => STRING,
      "last_used_at" => STRING_OR_NULL
    }
  )

  MCP_PROJECT_STATUS_RESPONSE = strict_object(
    required: %w[id name identifier test domain has_redirect_config has_links],
    properties: {
      "id" => ID,
      "name" => STRING_OR_NULL,
      "identifier" => STRING,
      "test" => BOOL,
      "domain" => STRING_OR_NULL,
      "has_redirect_config" => BOOL,
      "has_links" => BOOL
    }
  )

  MCP_USAGE_DETAILS_RESPONSE = strict_object(
    required: %w[current_mau mau_limit quota_exceeded has_subscription],
    properties: {
      "current_mau" => NUMBER,
      "mau_limit" => NUMBER,
      "quota_exceeded" => BOOL,
      "has_subscription" => BOOL
    }
  )

  MCP_INSTANCE_STATUS_RESPONSE = strict_object(
    required: %w[id name uri_scheme production test configurations usage],
    properties: {
      "id" => ID,
      "name" => STRING_OR_NULL,
      "uri_scheme" => STRING_OR_NULL,
      "production" => MCP_PROJECT_STATUS_RESPONSE.merge("type" => %w[object null]),
      "test" => MCP_PROJECT_STATUS_RESPONSE.merge("type" => %w[object null]),
      "configurations" => strict_object(
        required: %w[ios android web desktop],
        properties: {
          "ios" => BOOL,
          "android" => BOOL,
          "web" => BOOL,
          "desktop" => BOOL
        }
      ),
      "usage" => MCP_USAGE_DETAILS_RESPONSE
    }
  )

  MCP_REDIRECT_RULE_RESPONSE = strict_object(
    required: %w[id application_id appstore created_at enabled fallback_url platform redirect_config_id updated_at variation],
    properties: {
      "id" => ID,
      "application_id" => ID,
      "appstore" => BOOL,
      "created_at" => STRING,
      "enabled" => BOOL,
      "fallback_url" => STRING_OR_NULL,
      "platform" => STRING,
      "redirect_config_id" => ID,
      "updated_at" => STRING,
      "variation" => STRING
    }
  )

  MCP_REDIRECT_RULE_OR_NULL = MCP_REDIRECT_RULE_RESPONSE.merge("type" => %w[object null])

  MCP_REDIRECT_TARGET_RESPONSE = strict_object(
    required: %w[phone tablet],
    properties: {
      "phone" => MCP_REDIRECT_RULE_OR_NULL,
      "tablet" => MCP_REDIRECT_RULE_OR_NULL
    }
  )

  MCP_DESKTOP_REDIRECT_TARGET_RESPONSE = strict_object(
    required: %w[all],
    properties: {
      "all" => MCP_REDIRECT_RULE_OR_NULL
    }
  )

  MCP_REDIRECT_CONFIG_RESPONSE_BODY = strict_object(
    required: %w[default_fallback show_preview_ios show_preview_android ios android desktop],
    properties: {
      "default_fallback" => STRING_OR_NULL,
      "show_preview_ios" => BOOL_OR_NULL,
      "show_preview_android" => BOOL_OR_NULL,
      "ios" => MCP_REDIRECT_TARGET_RESPONSE,
      "android" => MCP_REDIRECT_TARGET_RESPONSE,
      "desktop" => MCP_DESKTOP_REDIRECT_TARGET_RESPONSE
    }
  )

  MCP_APPLICATION_RESPONSE = strict_object(
    required: %w[instance_id platform enabled configuration],
    properties: {
      "instance_id" => ID,
      "platform" => STRING,
      "enabled" => BOOL,
      "configuration" => JSON_VALUE
    }
  )

  MCP_PROJECT_RESPONSE = strict_object(
    required: %w[id name identifier test domain hash_id],
    properties: {
      "id" => ID,
      "name" => STRING_OR_NULL,
      "identifier" => STRING,
      "test" => BOOL,
      "domain" => STRING_OR_NULL,
      "hash_id" => STRING
    }
  )

  MCP_INSTANCE_RESPONSE_BODY = strict_object(
    required: %w[id api_key uri_scheme updated_at get_started_dismissed quota_exceeded revenue_collection_enabled production test hash_id],
    properties: {
      "id" => ID,
      "api_key" => STRING_OR_NULL,
      "uri_scheme" => STRING_OR_NULL,
      "updated_at" => STRING,
      "get_started_dismissed" => BOOL,
      "quota_exceeded" => BOOL,
      "revenue_collection_enabled" => BOOL,
      "production" => MCP_PROJECT_RESPONSE.merge("type" => %w[object null]),
      "test" => MCP_PROJECT_RESPONSE.merge("type" => %w[object null]),
      "hash_id" => STRING
    }
  )

  MCP_SLIM_LINK_RESPONSE = LINK_RESPONSE.merge(
    "required" => LINK_RESPONSE.fetch("required") - %w[image access_path ios_custom_redirect android_custom_redirect desktop_custom_redirect],
    "properties" => LINK_RESPONSE.fetch("properties")
      .except("image", "access_path", "ios_custom_redirect", "android_custom_redirect", "desktop_custom_redirect")
      .merge(
        "total_views" => NUMBER,
        "total_opens" => NUMBER,
        "total_installs" => NUMBER,
        "total_reinstalls" => NUMBER,
        "total_time_spent" => NUMBER,
        "total_reactivations" => NUMBER,
        "total_app_opens" => NUMBER,
        "total_user_referred" => NUMBER,
        "total_revenue" => NUMBER
      )
  )

  MCP_TOKENS_RESPONSE = strict_object(
    required: %w[tokens],
    properties: {
      "tokens" => {
        "type" => "array",
        "items" => MCP_TOKEN_RESPONSE
      }
    }
  )

  MCP_STATUS_RESPONSE = mcp_object(
    required: %w[user instances],
    properties: {
      "user" => strict_object(
        required: %w[id email name],
        properties: {
          "id" => ID,
          "email" => STRING,
          "name" => STRING_OR_NULL
        }
      ),
      "instances" => {
        "type" => "array",
        "items" => MCP_INSTANCE_STATUS_RESPONSE
      }
    }
  )

  MCP_VALIDATE_RESPONSE = mcp_object(
    required: %w[valid],
    properties: {
      "valid" => { "type" => "boolean" }
    }
  )

  MCP_USAGE_RESPONSE = mcp_object(
    required: %w[usage],
    properties: {
      "usage" => MCP_USAGE_DETAILS_RESPONSE
    }
  )

  MCP_LINK_ENVELOPE = mcp_object(
    required: %w[link],
    properties: {
      "link" => LINK_RESPONSE
    }
  )

  MCP_CAMPAIGN_RESPONSE = strict_object(
    required: %w[id name archived created_at has_links],
    properties: {
      "id" => ID,
      "name" => STRING,
      "archived" => BOOL,
      "created_at" => STRING,
      "has_links" => BOOL,
      "total_views" => NUMBER,
      "total_opens" => NUMBER,
      "total_installs" => NUMBER,
      "total_reinstalls" => NUMBER,
      "total_time_spent" => NUMBER,
      "total_reactivations" => NUMBER,
      "total_app_opens" => NUMBER,
      "total_user_referred" => NUMBER,
      "total_revenue" => NUMBER
    }
  )

  MCP_CAMPAIGN_ENVELOPE = mcp_object(
    required: %w[campaign],
    properties: {
      "campaign" => MCP_CAMPAIGN_RESPONSE
    }
  )

  MCP_CAMPAIGNS_RESPONSE = mcp_object(
    required: %w[campaigns meta],
    properties: {
      "campaigns" => {
        "type" => "array",
        "items" => MCP_CAMPAIGN_RESPONSE
      },
      "meta" => strict_object(
        required: %w[page per_page total_pages total_entries],
        properties: {
          "page" => { "type" => "integer" },
          "per_page" => { "type" => "integer" },
          "total_pages" => { "type" => "integer" },
          "total_entries" => { "type" => "integer" }
        }
      )
    }
  )

  MCP_REDIRECT_CONFIG_RESPONSE = mcp_object(
    required: %w[redirect_config],
    properties: {
      "redirect_config" => MCP_REDIRECT_CONFIG_RESPONSE_BODY
    }
  )

  MCP_CONFIGURATIONS_RESPONSE = mcp_object(
    required: %w[configurations],
    properties: {
      "configurations" => {
        "type" => "object",
        "additionalProperties" => MCP_APPLICATION_RESPONSE
      }
    }
  )

  MCP_INSTANCE_RESPONSE = mcp_object(
    required: %w[instance],
    properties: {
      "instance" => MCP_INSTANCE_RESPONSE_BODY
    }
  )

  MCP_ANALYTICS_LINK_RESPONSE = mcp_object(
    required: %w[link_path metrics],
    properties: {
      "link_path" => STRING,
      "metrics" => ANY_OBJECT
    }
  )

  MCP_ANALYTICS_METRICS_RESPONSE = mcp_object(
    required: %w[metrics],
    properties: {
      "metrics" => ANY_OBJECT
    }
  )

  MCP_TOP_LINKS_RESPONSE = mcp_object(
    required: %w[links],
    properties: {
      "links" => ARRAY
    }
  )

  MCP_LINKS_SEARCH_RESPONSE = mcp_object(
    required: %w[links meta],
    properties: {
      "links" => {
        "type" => "array",
        "items" => MCP_SLIM_LINK_RESPONSE
      },
      "meta" => strict_object(
        required: %w[page total_pages per_page total_entries],
        properties: {
          "page" => { "type" => "integer" },
          "total_pages" => { "type" => "integer" },
          "per_page" => { "type" => "integer" },
          "total_entries" => { "type" => "integer" }
        }
      )
    }
  )

  MCP_AUTH_FAILURES = {
    401 => MCP_ERROR,
    403 => MCP_ERROR
  }.freeze

  MCP_BAD_REQUEST = {
    "oneOf" => [
      MCP_ERROR,
      RAILS_EXCEPTION_RESPONSE
    ]
  }.freeze

  MCP_DOORKEEPER_AUTH_FAILURE = {
    401 => AUTH_ERROR
  }.freeze

  register "Api::V1::Mcp::AnalyticsController#link_stats",
           request: MCP_LINK_STATS_REQUEST,
           responses: {
             200 => MCP_ANALYTICS_LINK_RESPONSE,
             400 => MCP_BAD_REQUEST,
             404 => MCP_ERROR,
             **MCP_AUTH_FAILURES
           }

  register "Api::V1::Mcp::AnalyticsController#project_metrics",
           request: MCP_DATE_RANGE_REQUEST,
           responses: {
             200 => MCP_ANALYTICS_METRICS_RESPONSE,
             400 => MCP_BAD_REQUEST,
             404 => MCP_ERROR,
             **MCP_AUTH_FAILURES
           }

  register "Api::V1::Mcp::AnalyticsController#top_links",
           request: MCP_TOP_LINKS_REQUEST,
           responses: {
             200 => MCP_TOP_LINKS_RESPONSE,
             400 => MCP_BAD_REQUEST,
             404 => MCP_ERROR,
             **MCP_AUTH_FAILURES
           }

  register "Api::V1::Mcp::AuthController#approve_consent",
             request: MCP_CONSENT_REQUEST,
             responses: {
               200 => MCP_AUTH_CODE_RESPONSE,
               400 => MCP_BAD_REQUEST,
               **MCP_DOORKEEPER_AUTH_FAILURE
             }

  register "Api::V1::Mcp::AuthController#list_tokens",
             request: MCP_NO_PARAMS,
             responses: {
               200 => MCP_TOKENS_RESPONSE,
               **MCP_DOORKEEPER_AUTH_FAILURE
             }

  register "Api::V1::Mcp::AuthController#revoke_token_by_id",
             request: MCP_NO_PARAMS,
             responses: {
               200 => MCP_MESSAGE,
               404 => MCP_ERROR,
               **MCP_DOORKEEPER_AUTH_FAILURE
             }

  %w[
    Api::V1::Mcp::AuthController#revoke_token
    Api::V1::Mcp::AuthController#status
    Api::V1::Mcp::AuthController#validate
  ].each do |action|
    register action,
               request: MCP_NO_PARAMS,
               responses: {
                 200 => if action.end_with?("#status")
                          MCP_STATUS_RESPONSE
                        else
                          action.end_with?("#validate") ? MCP_VALIDATE_RESPONSE : MCP_MESSAGE
                        end,
                 401 => MCP_ERROR
               }
  end

  register "Api::V1::Mcp::AuthController#usage",
             request: MCP_USAGE_REQUEST,
             responses: {
               200 => MCP_USAGE_RESPONSE,
               400 => MCP_BAD_REQUEST,
               401 => MCP_ERROR,
               404 => MCP_ERROR
             }

  register "Api::V1::Mcp::CampaignsController#index",
           request: MCP_SEARCH_REQUEST,
           responses: {
               200 => MCP_CAMPAIGNS_RESPONSE,
               400 => MCP_BAD_REQUEST,
               401 => MCP_ERROR,
               403 => MCP_ERROR,
               404 => MCP_ERROR
             }

  register "Api::V1::Mcp::CampaignsController#archive",
           request: MCP_PROJECT_REQUEST,
           responses: {
               200 => MCP_CAMPAIGN_ENVELOPE,
               400 => MCP_BAD_REQUEST,
               401 => MCP_ERROR,
               403 => MCP_ERROR,
               404 => MCP_ERROR,
               422 => MCP_ERROR
             }

  register "Api::V1::Mcp::CampaignsController#create",
           request: MCP_CAMPAIGN_CREATE_REQUEST,
           responses: {
               201 => MCP_CAMPAIGN_ENVELOPE,
               400 => MCP_BAD_REQUEST,
               401 => MCP_ERROR,
               403 => MCP_ERROR,
               404 => MCP_ERROR,
               422 => MCP_ERROR
             }

  %w[
    Api::V1::Mcp::ConfigurationsController#setup_redirects
    Api::V1::Mcp::ConfigurationsController#setup_sdk
  ].each do |action|
    register action,
             request: action.end_with?("#setup_redirects") ? MCP_SETUP_REDIRECTS_REQUEST : MCP_SETUP_SDK_REQUEST,
             responses: {
                 200 => action.end_with?("#setup_redirects") ? MCP_REDIRECT_CONFIG_RESPONSE : MCP_CONFIGURATIONS_RESPONSE,
                 400 => MCP_BAD_REQUEST,
                 401 => MCP_ERROR,
                 403 => MCP_ERROR,
                 404 => MCP_ERROR
               }
  end

  %w[
    Api::V1::Mcp::LinksController#index
    Api::V1::Mcp::LinksController#show
  ].each do |action|
    register action,
             request: action.end_with?("#index") ? MCP_SEARCH_REQUEST : MCP_PROJECT_REQUEST,
             responses: {
                 200 => action.end_with?("#index") ? MCP_LINKS_SEARCH_RESPONSE : MCP_LINK_ENVELOPE,
                 400 => MCP_BAD_REQUEST,
                 401 => MCP_ERROR,
                 403 => MCP_ERROR,
                 404 => MCP_ERROR
               }
  end

  register "Api::V1::Mcp::LinksController#archive",
           request: MCP_PROJECT_REQUEST,
           responses: {
               200 => MCP_LINK_ENVELOPE,
               400 => MCP_BAD_REQUEST,
               401 => MCP_ERROR,
               403 => MCP_ERROR,
               404 => MCP_ERROR,
               422 => MCP_ERROR
             }

  register "Api::V1::Mcp::LinksController#update",
           request: MCP_LINK_MUTATION_REQUEST,
           responses: {
               200 => MCP_LINK_ENVELOPE,
               400 => MCP_BAD_REQUEST,
               401 => MCP_ERROR,
               403 => MCP_ERROR,
               404 => MCP_ERROR,
               422 => MCP_ERROR
             }

  register "Api::V1::Mcp::LinksController#create",
           request: MCP_LINK_CREATE_REQUEST,
           responses: {
               201 => MCP_LINK_ENVELOPE,
               400 => MCP_BAD_REQUEST,
               401 => MCP_ERROR,
               403 => MCP_ERROR,
               404 => MCP_ERROR,
               422 => MCP_ERROR
             }

  register "Api::V1::Mcp::ProjectsController#create",
           request: MCP_PROJECT_CREATE_REQUEST,
           responses: {
               201 => MCP_INSTANCE_RESPONSE,
               400 => MCP_BAD_REQUEST,
               401 => MCP_ERROR,
               422 => MCP_ERROR
             }
end
