require_relative "external_api_contracts"
require_relative "mcp_contracts"
require_relative "sdk_contracts"

# Formal contracts for the dashboard/admin first-party API surface. Complex
# aggregate payloads are represented as JSON values, but endpoint envelopes,
# request param allowlists, and serializer-backed resources are locked.
module ApiContracts # rubocop:disable Metrics/ModuleLength
  DATE_FILTERS = {
    "start_date" => STRING_OR_NULL,
    "end_date" => STRING_OR_NULL
  }.freeze

  SEARCH_FILTERS = DATE_FILTERS.merge(
    "project_id" => STRING_OR_NULL,
    "instance_id" => STRING_OR_NULL,
    "page" => { "type" => %w[integer string null] },
    "per_page" => { "type" => %w[integer string null] },
    "term" => STRING_OR_NULL,
    "sort_by" => STRING_OR_NULL,
    "ascendent" => { "type" => %w[boolean string null] },
    "archived" => { "type" => %w[boolean string null] },
    "active" => { "type" => %w[boolean string null] },
    "sdk" => { "type" => %w[boolean string null] },
    "sdk_generated" => { "type" => %w[boolean string null] },
    "ads_platform" => STRING_OR_NULL,
    "campaign_id" => { "type" => %w[integer string null] },
    "platform" => { "type" => %w[string array null] },
    "platforms" => ARRAY_OR_NULL,
    "app_versions" => ARRAY_OR_NULL,
    "build_versions" => ARRAY_OR_NULL,
    "event_type" => STRING_OR_NULL
  ).freeze

  SEARCH_REQUEST = strict_object(required: [], properties: SEARCH_FILTERS)

  USER_RESPONSE = strict_object(
    required: %w[id email name otp_required_for_login provider uid invitation_accepted_at invitation_sent_at],
    properties: {
      "id" => ID,
      "email" => STRING,
      "name" => STRING_OR_NULL,
      "otp_required_for_login" => BOOL_OR_NULL,
      "provider" => STRING_OR_NULL,
      "uid" => STRING_OR_NULL,
      "invitation_accepted_at" => STRING_OR_NULL,
      "invitation_sent_at" => STRING_OR_NULL,
      "roles" => ARRAY_OR_NULL
    }
  )

  AUTH_TOKEN_RESPONSE = strict_object(
    required: %w[user access_token token_type expires_in refresh_token created_at],
    properties: {
      "user" => USER_RESPONSE,
      "access_token" => STRING,
      "token_type" => STRING,
      "expires_in" => { "type" => "integer" },
      "refresh_token" => STRING,
      "created_at" => { "type" => "integer" }
    }
  )

  USER_ENVELOPE = strict_object(required: %w[user], properties: { "user" => USER_RESPONSE })

  PROJECT_RESPONSE = strict_object(
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

  INSTANCE_RESPONSE = strict_object(
    required: %w[
      id api_key uri_scheme updated_at get_started_dismissed quota_exceeded
      revenue_collection_enabled production test hash_id
    ],
    properties: {
      "id" => ID,
      "api_key" => STRING_OR_NULL,
      "uri_scheme" => STRING_OR_NULL,
      "updated_at" => STRING,
      "get_started_dismissed" => BOOL,
      "quota_exceeded" => BOOL,
      "revenue_collection_enabled" => BOOL,
      "production" => PROJECT_RESPONSE.merge("type" => %w[object null]),
      "test" => PROJECT_RESPONSE.merge("type" => %w[object null]),
      "hash_id" => STRING
    }
  )

  INSTANCE_ENVELOPE = strict_object(required: %w[instance], properties: { "instance" => INSTANCE_RESPONSE })
  INSTANCE_PROJECT_ENVELOPE = strict_object(required: %w[project], properties: { "project" => INSTANCE_RESPONSE })
  INSTANCES_ENVELOPE = strict_object(
    required: %w[instances],
    properties: { "instances" => { "type" => "array", "items" => INSTANCE_RESPONSE } }
  )

  INSTANCE_SETUP_RESPONSE = strict_object(
    required: %w[instance get_started_setup],
    properties: {
      "instance" => INSTANCE_RESPONSE,
      "get_started_setup" => strict_object(
        required: %w[ios_sdk android_sdk web_sdk redirect_fallback has_created_links has_created_campaigns],
        properties: {
          "ios_sdk" => BOOL,
          "android_sdk" => BOOL,
          "web_sdk" => BOOL,
          "redirect_fallback" => BOOL,
          "has_created_links" => BOOL,
          "has_created_campaigns" => BOOL_OR_NULL
        }
      )
    }
  )

  INSTANCE_ROLE_RESPONSE = strict_object(
    required: %w[instance_id role user],
    properties: {
      "instance_id" => ID,
      "role" => STRING,
      "user" => USER_RESPONSE
    }
  )

  MEMBERS_RESPONSE = strict_object(
    required: %w[members],
    properties: { "members" => { "type" => "array", "items" => INSTANCE_ROLE_RESPONSE } }
  )
  ROLE_ENVELOPE = strict_object(required: %w[role], properties: { "role" => INSTANCE_ROLE_RESPONSE })
  ROLE_ADDED_ENVELOPE = strict_object(required: %w[role_added], properties: { "role_added" => INSTANCE_ROLE_RESPONSE })

  SETUP_STEP_RESPONSE = strict_object(
    required: %w[category step_identifier completed_at],
    properties: {
      "category" => STRING,
      "step_identifier" => STRING,
      "completed_at" => STRING_OR_NULL
    }
  )
  SETUP_STEPS_ENVELOPE = strict_object(
    required: %w[steps],
    properties: { "steps" => { "type" => "array", "items" => SETUP_STEP_RESPONSE } }
  )
  SETUP_STEP_ENVELOPE = strict_object(required: %w[step], properties: { "step" => SETUP_STEP_RESPONSE })

  DOMAIN_RESPONSE = strict_object(
    required: %w[domain subdomain generic_title generic_subtitle google_tracking_id generic_image_url],
    properties: {
      "domain" => STRING_OR_NULL,
      "subdomain" => STRING_OR_NULL,
      "generic_title" => STRING_OR_NULL,
      "generic_subtitle" => STRING_OR_NULL,
      "google_tracking_id" => STRING_OR_NULL,
      "generic_image_url" => STRING_OR_NULL
    }
  )
  DOMAIN_ENVELOPE = strict_object(required: %w[domain], properties: { "domain" => DOMAIN_RESPONSE })

  DOMAIN_DEFAULTS_RESPONSE = strict_object(
    required: %w[generic_title generic_subtitle generic_image_url],
    properties: {
      "generic_title" => STRING,
      "generic_subtitle" => STRING,
      "generic_image_url" => STRING
    }
  )
  AVAILABLE_RESPONSE = strict_object(required: %w[available], properties: { "available" => { "type" => "boolean" } })

  APPLICATION_RESPONSE = strict_object(
    required: %w[instance_id platform enabled configuration],
    properties: {
      "instance_id" => ID,
      "platform" => STRING,
      "enabled" => BOOL,
      "configuration" => JSON_VALUE
    }
  )
  CONFIG_ENVELOPE = strict_object(required: %w[config], properties: { "config" => { "type" => %w[object null] } })
  CONFIGURATIONS_ENVELOPE = strict_object(
    required: %w[configurations],
    properties: { "configurations" => { "type" => "array", "items" => APPLICATION_RESPONSE } }
  )

  REDIRECT_CONFIG_RESPONSE = {
    "type" => "object",
    "additionalProperties" => true,
    "properties" => {
      "default_fallback" => STRING_OR_NULL,
      "show_preview_android" => BOOL_OR_NULL,
      "show_preview_ios" => BOOL_OR_NULL
    }
  }.freeze
  REDIRECT_CONFIG_ENVELOPE = strict_object(required: %w[redirect_config], properties: { "redirect_config" => REDIRECT_CONFIG_RESPONSE })
  REDIRECT_CONFIG_AS_CONFIG_ENVELOPE = strict_object(required: %w[config], properties: { "config" => REDIRECT_CONFIG_RESPONSE })

  CAMPAIGN_ENVELOPE = strict_object(required: %w[campaign], properties: { "campaign" => MCP_CAMPAIGN_RESPONSE })
  PAGINATED_RESPONSE = strict_object(
    required: %w[data page per_page total_pages total_entries],
    properties: {
      "data" => { "type" => %w[array object] },
      "page" => { "type" => "integer" },
      "per_page" => { "type" => "integer" },
      "total_pages" => { "type" => "integer" },
      "total_entries" => { "type" => "integer" }
    }
  )

  LINKS_ENVELOPE = strict_object(
    required: %w[links],
    properties: { "links" => { "type" => "array", "items" => LINK_RESPONSE } }
  )
  LINK_ENVELOPE = strict_object(required: %w[link], properties: { "link" => LINK_RESPONSE })
  GENERATED_PATH_RESPONSE = strict_object(required: %w[valid_path], properties: { "valid_path" => STRING })
  DASHBOARD_LINK_REQUEST = strict_object(
    required: [],
    properties: SDK_LINK_CREATE_REQUEST.fetch("properties").merge(
      "path" => STRING_OR_NULL,
      "campaign_id" => { "type" => %w[integer string null] }
    )
  )

  METRICS_ENVELOPE = strict_object(required: %w[metrics], properties: { "metrics" => { "type" => %w[object array] } })
  LINKS_METRICS_ENVELOPE = strict_object(required: %w[links], properties: { "links" => ARRAY })
  METRICS_VALUES_RESPONSE = strict_object(
    required: %w[metrics_values],
    properties: {
      "metrics_values" => strict_object(
        required: %w[platforms app_versions builds],
        properties: {
          "platforms" => ARRAY,
          "app_versions" => ARRAY,
          "builds" => ARRAY
        }
      )
    }
  )

  NOTIFICATION_TARGET_RESPONSE = strict_object(
    required: %w[id existing_users new_users platforms],
    properties: {
      "id" => ID,
      "existing_users" => BOOL,
      "new_users" => BOOL,
      "platforms" => ARRAY_OR_NULL
    }
  )
  NOTIFICATION_RESPONSE = strict_object(
    required: %w[id title subtitle html archived auto_display send_push updated_at target access_url],
    properties: {
      "id" => ID,
      "title" => STRING_OR_NULL,
      "subtitle" => STRING_OR_NULL,
      "html" => STRING_OR_NULL,
      "archived" => BOOL,
      "auto_display" => BOOL,
      "send_push" => BOOL,
      "updated_at" => STRING,
      "read_count" => { "type" => %w[integer null] },
      "target" => NOTIFICATION_TARGET_RESPONSE,
      "access_url" => STRING
    }
  )
  NOTIFICATION_ENVELOPE = strict_object(required: %w[notification], properties: { "notification" => NOTIFICATION_RESPONSE })
  NOTIFICATIONS_ARCHIVE_ENVELOPE = strict_object(
    required: %w[notifications],
    properties: { "notifications" => NOTIFICATION_RESPONSE }
  )

  URL_RESPONSE = strict_object(required: %w[url], properties: { "url" => STRING })
  RESULT_RESPONSE = strict_object(required: %w[result], properties: { "result" => { "type" => %w[object boolean string null] } })
  AUTOMATION_VISITOR_RESPONSE = strict_object(
    required: %w[id uuid sdk_identifier sdk_attributes inviter_id web_visitor created_at updated_at inviter],
    properties: {
      "id" => ID,
      "uuid" => STRING,
      "sdk_identifier" => STRING_OR_NULL,
      "sdk_attributes" => SDK_ATTRIBUTES,
      "inviter_id" => INTEGER_OR_NULL,
      "web_visitor" => BOOL,
      "created_at" => STRING,
      "updated_at" => STRING,
      "inviter" => STRING_OR_NULL
    }
  )
  DYNAMIC_OBJECT_RESPONSE = {
    "type" => "object",
    "additionalProperties" => true
  }.freeze
  DYNAMIC_ARRAY_RESPONSE = {
    "type" => "array",
    "items" => JSON_VALUE
  }.freeze
  DASHBOARD_METRIC_BUCKET = strict_object(
    required: %w[
      views link_views link_driven_installs organic_users opens installs
      reinstalls app_opens new_users returning_users returning_rate
      referred_users revenue units_sold cancellations first_time_purchases
      arpu arppu
    ],
    properties: {
      "views" => NUMBER,
      "link_views" => NUMBER,
      "link_driven_installs" => NUMBER,
      "organic_users" => NUMBER,
      "opens" => NUMBER,
      "installs" => NUMBER,
      "reinstalls" => NUMBER,
      "app_opens" => NUMBER,
      "new_users" => NUMBER,
      "returning_users" => NUMBER,
      "returning_rate" => NUMBER,
      "referred_users" => NUMBER,
      "revenue" => NUMBER,
      "units_sold" => NUMBER,
      "cancellations" => NUMBER,
      "first_time_purchases" => NUMBER,
      "arpu" => NUMBER,
      "arppu" => NUMBER
    }
  )
  DASHBOARD_METRICS_RESPONSE = strict_object(
    required: %w[current previous],
    properties: {
      "current" => DASHBOARD_METRIC_BUCKET,
      "previous" => DASHBOARD_METRIC_BUCKET
    }
  )
  EVENT_COUNT_BUCKET = strict_object(
    required: [],
    properties: {
      "view" => NUMBER,
      "open" => NUMBER,
      "install" => NUMBER,
      "reinstall" => NUMBER,
      "reactivation" => NUMBER,
      "avg_engagement_time" => NUMBER,
      "user_referred" => NUMBER,
      "app_open" => NUMBER,
      "time_spent" => NUMBER
    }
  )
  EVENT_TIMESERIES_RESPONSE = {
    "type" => "object",
    "additionalProperties" => EVENT_COUNT_BUCKET
  }.freeze
  LINK_EVENT_METRICS_MAP = {
    "type" => "object",
    "additionalProperties" => EVENT_COUNT_BUCKET
  }.freeze
  SORTED_LINK_RAW_RESPONSE = strict_object(
    required: %w[
      id active ads_platform campaign_id created_at data domain_id generated_from_platform
      image_url name path redirect_config_id sdk_generated show_preview_android
      show_preview_ios subtitle tags title tracking_campaign tracking_medium tracking_source
      updated_at visitor_id view_count
    ],
    properties: {
      "id" => ID,
      "active" => BOOL,
      "ads_platform" => STRING_OR_NULL,
      "campaign_id" => INTEGER_OR_NULL,
      "created_at" => STRING,
      "data" => JSON_VALUE,
      "domain_id" => ID,
      "generated_from_platform" => STRING_OR_NULL,
      "image_url" => STRING_OR_NULL,
      "migrated_from" => STRING_OR_NULL,
      "name" => STRING_OR_NULL,
      "path" => STRING,
      "redirect_config_id" => INTEGER_OR_NULL,
      "sdk_generated" => BOOL,
      "show_preview_android" => BOOLEAN_OR_NULL,
      "show_preview_ios" => BOOLEAN_OR_NULL,
      "subtitle" => STRING_OR_NULL,
      "tags" => ARRAY_OR_NULL,
      "title" => STRING_OR_NULL,
      "tracking_campaign" => STRING_OR_NULL,
      "tracking_medium" => STRING_OR_NULL,
      "tracking_source" => STRING_OR_NULL,
      "updated_at" => STRING,
      "visitor_id" => INTEGER_OR_NULL,
      "view_count" => NUMBER
    }
  )
  EVENTS_SORTED_RESPONSE = {
    "oneOf" => [
      {
        "type" => "array",
        "items" => strict_object(required: %w[link metrics], 
properties: { "link" => SORTED_LINK_RAW_RESPONSE, "metrics" => EVENT_COUNT_BUCKET.merge("type" => %w[object null]) })
      },
      strict_object(
        required: %w[result page total_pages],
        properties: {
          "result" => {
            "type" => "array",
            "items" => strict_object(required: %w[link metrics], 
properties: { "link" => SORTED_LINK_RAW_RESPONSE, "metrics" => EVENT_COUNT_BUCKET.merge("type" => %w[object null]) })
          },
          "page" => { "type" => %w[integer string] },
          "total_pages" => { "type" => "integer" }
        }
      )
    ]
  }.freeze
  VISITOR_QUERY_RESPONSE = strict_object(
    required: %w[visitors meta],
    properties: {
      "visitors" => ARRAY,
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
  VISITOR_DETAIL_RESPONSE = strict_object(
    required: %w[visitor metrics aggregated_metrics number_of_generated_links],
    properties: {
      "visitor" => VISITOR_RESPONSE,
      "metrics" => { "type" => %w[object null] },
      "aggregated_metrics" => { "type" => %w[object null] },
      "number_of_generated_links" => { "type" => "integer" }
    }
  )
  DATE_NUMBER_MAP_RESPONSE = {
    "type" => "object",
    "additionalProperties" => NUMBER
  }.freeze
  PAYMENT_SCREEN_EVENTS_RESPONSE = strict_object(
    required: %w[metrics_values],
    properties: {
      "metrics_values" => DATE_NUMBER_MAP_RESPONSE
    }
  )
  TOP_LINK_RESPONSE = LINK_RESPONSE.merge(
    "required" => LINK_RESPONSE.fetch("required") + %w[views opens installs reinstalls reactivations time_spent],
    "properties" => LINK_RESPONSE.fetch("properties").merge(
      "views" => NUMBER,
      "opens" => NUMBER,
      "installs" => NUMBER,
      "reinstalls" => NUMBER,
      "reactivations" => NUMBER,
      "time_spent" => NUMBER
    )
  )
  TOP_LINKS_RESPONSE = strict_object(
    required: %w[links],
    properties: {
      "links" => {
        "type" => "array",
        "items" => TOP_LINK_RESPONSE
      }
    }
  )
  SSO_REDIRECT_URL_RESPONSE = strict_object(required: %w[redirect_url], properties: { "redirect_url" => STRING })
  SSO_TOKEN_RESPONSE = strict_object(required: %w[token refresh_token], properties: { "token" => STRING, "refresh_token" => STRING })
  ADMIN_SUBSCRIPTION_RESPONSE = strict_object(
    required: %w[message subscription],
    properties: { "message" => STRING, "subscription" => DYNAMIC_OBJECT_RESPONSE }
  )
  BILLING_SUBSCRIPTION_DETAILS_RESPONSE = {
    "oneOf" => [
      strict_object(
        required: %w[type details stripe_subscription quantity_for_current_billing_cycle amount_cents amount_formatted maus period_start period_end 
next_payment_attempt],
        properties: {
          "type" => { "enum" => ["stripe"] },
          "details" => strict_object(
            required: %w[active paused],
            properties: {
              "active" => BOOL,
              "paused" => BOOL,
              "price" => { "type" => %w[number integer null] }
            }
          ),
          "stripe_subscription" => { "type" => %w[object null], "additionalProperties" => true },
          "quantity_for_current_billing_cycle" => NUMBER,
          "amount_cents" => { "type" => %w[number integer null] },
          "amount_formatted" => STRING_OR_NULL,
          "maus" => { "type" => %w[number integer null] },
          "period_start" => { "type" => %w[string integer null] },
          "period_end" => { "type" => %w[string integer null] },
          "next_payment_attempt" => { "type" => %w[string integer null] }
        }
      ),
      strict_object(
        required: %w[type current_maus total_maus start_at end_at],
        properties: {
          "type" => { "enum" => ["enterprise"] },
          "current_maus" => NUMBER,
          "total_maus" => NUMBER,
          "start_at" => STRING_OR_NULL,
          "end_at" => STRING_OR_NULL
        }
      ),
      strict_object(
        required: %w[plan status mau_limit],
        properties: {
          "plan" => STRING,
          "status" => STRING,
          "mau_limit" => NUMBER
        }
      )
    ]
  }.freeze
  CURRENT_MAU_RESPONSE = strict_object(
    required: %w[current_quantity total_available],
    properties: {
      "current_quantity" => NUMBER,
      "total_available" => STRING
    }
  )
  BILLING_USAGE_RESPONSE = {
    "oneOf" => [
      strict_object(
        required: %w[amount maus next_payment_attempt start_date],
        properties: {
          "amount" => { "type" => %w[number integer null] },
          "maus" => { "type" => %w[number integer null] },
          "next_payment_attempt" => { "type" => %w[string integer null] },
          "start_date" => { "type" => %w[string integer null] }
        }
      ),
      strict_object(
        required: %w[type current_maus total_maus start_at end_at],
        properties: {
          "type" => { "enum" => ["enterprise"] },
          "current_maus" => NUMBER,
          "total_maus" => NUMBER,
          "start_at" => STRING_OR_NULL,
          "end_at" => STRING_OR_NULL
        }
      )
    ]
  }.freeze
  NUMBER_OR_NULL = { "type" => %w[number integer null] }.freeze

  # Both purchases endpoints render through PaginatedResponse:
  # { data: [...], page:, per_page:, total_pages:, total_entries: }.
  def self.paginated(items_schema)
    strict_object(
      required: %w[data page per_page total_pages total_entries],
      properties: {
        "data" => { "type" => "array", "items" => items_schema },
        "page" => { "type" => "integer" },
        "per_page" => { "type" => "integer" },
        "total_pages" => { "type" => "integer" },
        "total_entries" => { "type" => "integer" }
      }
    )
  end

  # PurchaseEventSerializer output (+ platform/link_id added in build).
  PURCHASE_EVENT = strict_object(
    required: %w[id event_type purchase_type product_id identifier transaction_id
                 original_transaction_id price_cents usd_price_cents currency
                 date expires_date processed store store_source webhook_validated
                 quantity order_id platform link_id],
    properties: {
      "id" => { "type" => "integer" },
      "event_type" => STRING,
      "purchase_type" => STRING_OR_NULL,
      "product_id" => STRING_OR_NULL,
      "identifier" => STRING_OR_NULL,
      "transaction_id" => STRING_OR_NULL,
      "original_transaction_id" => STRING_OR_NULL,
      "price_cents" => NUMBER_OR_NULL,
      "usd_price_cents" => NUMBER_OR_NULL,
      "currency" => STRING_OR_NULL,
      "date" => STRING_OR_NULL,
      "expires_date" => STRING_OR_NULL,
      "processed" => BOOLEAN_OR_NULL,
      "store" => BOOLEAN_OR_NULL,
      "store_source" => STRING_OR_NULL,
      "webhook_validated" => BOOLEAN_OR_NULL,
      "quantity" => INTEGER_OR_NULL,
      "order_id" => STRING_OR_NULL,
      "platform" => STRING_OR_NULL,
      "link_id" => INTEGER_OR_NULL
    }
  )
  PURCHASES_RESPONSE = paginated(PURCHASE_EVENT)

  # RevenueMetricsQuery#with_arpu rows. `platforms` is a JSON-encoded string
  # (to_json(ARRAY_AGG(...)) in raw SQL), not a parsed array.
  REVENUE_METRICS_ROW = strict_object(
    required: %w[project_id product_id platforms units_sold first_time_purchases
                 repeat_purchases cancellations total_revenue_usd_cents
                 unique_purchasers ltv_usd_cents arpu_usd_cents arppu_usd_cents],
    properties: {
      "project_id" => { "type" => "integer" },
      "product_id" => STRING,
      "platforms" => STRING_OR_NULL,
      "units_sold" => NUMBER,
      "first_time_purchases" => NUMBER,
      "repeat_purchases" => NUMBER,
      "cancellations" => NUMBER,
      "total_revenue_usd_cents" => NUMBER,
      "unique_purchasers" => NUMBER,
      "ltv_usd_cents" => NUMBER_OR_NULL,
      "arpu_usd_cents" => NUMBER_OR_NULL,
      "arppu_usd_cents" => NUMBER_OR_NULL
    }
  )
  REVENUE_METRICS_RESPONSE = paginated(REVENUE_METRICS_ROW)
  FIREBASE_MIGRATION_RESPONSE = strict_object(
    required: %w[created_count skipped_count skipped links],
    properties: {
      "created_count" => { "type" => "integer" },
      "skipped_count" => { "type" => "integer" },
      "skipped" => {
        "type" => "array",
        "items" => strict_object(
          required: %w[reason name path],
          properties: {
            "reason" => STRING,
            "name" => STRING,
            "path" => STRING
          }
        )
      },
      "links" => ARRAY
    }
  )
  DIAGNOSTIC_LOG_ENTRY_RESPONSE = strict_object(
    required: %w[test_id message hostname process_type environment timestamp request_ip iteration],
    properties: {
      "test_id" => STRING,
      "message" => STRING,
      "hostname" => STRING,
      "process_type" => STRING,
      "environment" => STRING,
      "timestamp" => STRING,
      "request_ip" => STRING_OR_NULL,
      "iteration" => { "type" => "integer" }
    }
  )
  DIAGNOSTIC_LOGS_RESPONSE = strict_object(
    required: %w[status logs_generated level hostname process_type environment logs],
    properties: {
      "status" => STRING,
      "logs_generated" => { "type" => "integer" },
      "level" => STRING,
      "hostname" => STRING,
      "process_type" => STRING,
      "environment" => STRING,
      "logs" => {
        "type" => "array",
        "items" => DIAGNOSTIC_LOG_ENTRY_RESPONSE
      }
    }
  )
  DIAGNOSTIC_ERROR_ENTRY_RESPONSE = strict_object(
    required: %w[operation error],
    properties: {
      "operation" => STRING,
      "error" => STRING
    }
  )
  DIAGNOSTIC_RESULTS_RESPONSE = strict_object(
    required: %w[operations total_ms errors],
    properties: {
      "operations" => {
        "type" => "array",
        "items" => {
          "type" => "object",
          "additionalProperties" => { "type" => %w[number integer null] }
        }
      },
      "total_ms" => NUMBER,
      "errors" => {
        "type" => "array",
        "items" => DIAGNOSTIC_ERROR_ENTRY_RESPONSE
      },
      "records_created" => { "type" => "integer" },
      "records_deleted" => { "type" => "integer" },
      "cleanup_ms" => NUMBER,
      "server_info" => strict_object(
        required: %w[redis_version connected_clients used_memory_human total_commands_processed],
        properties: {
          "redis_version" => STRING,
          "connected_clients" => STRING,
          "used_memory_human" => STRING,
          "total_commands_processed" => STRING
        }
      )
    }
  )
  DIAGNOSTIC_SUMMARY_RESPONSE = strict_object(
    required: %w[postgresql redis status],
    properties: {
      "postgresql" => strict_object(
        required: %w[total_ms avg_ms_per_iteration records_created records_deleted errors],
        properties: {
          "total_ms" => NUMBER,
          "avg_ms_per_iteration" => NUMBER,
          "records_created" => { "type" => "integer" },
          "records_deleted" => { "type" => "integer" },
          "errors" => { "type" => "integer" }
        }
      ),
      "redis" => strict_object(
        required: %w[total_ms avg_ms_per_iteration errors],
        properties: {
          "total_ms" => NUMBER,
          "avg_ms_per_iteration" => NUMBER,
          "errors" => { "type" => "integer" }
        }
      ),
      "status" => STRING
    }
  )
  DIAGNOSTICS_RESPONSE = strict_object(
    required: %w[timestamp hostname environment iterations postgresql redis summary],
    properties: {
      "timestamp" => STRING,
      "hostname" => STRING,
      "environment" => STRING,
      "iterations" => { "type" => "integer" },
      "postgresql" => DIAGNOSTIC_RESULTS_RESPONSE,
      "redis" => DIAGNOSTIC_RESULTS_RESPONSE,
      "summary" => DIAGNOSTIC_SUMMARY_RESPONSE
    }
  )
  FLUSH_EVENTS_RESPONSE = strict_object(
    required: %w[message processed discarded dates_aggregated],
    properties: {
      "message" => STRING,
      "processed" => { "type" => "integer" },
      "discarded" => { "type" => "integer" },
      "dates_aggregated" => ARRAY
    }
  )

  # Users
  register "Api::V1::UsersController#create",
           request: strict_object(required: %w[email password client_id], 
properties: { "email" => STRING, "password" => STRING, "name" => STRING_OR_NULL, "client_id" => STRING }),
           responses: { 200 => AUTH_TOKEN_RESPONSE, 403 => ERROR, 409 => ERROR }
  register "Api::V1::UsersController#accept_invite",
           request: strict_object(required: %w[password invitation_token client_id], 
properties: { "password" => STRING, "invitation_token" => STRING, "name" => STRING_OR_NULL, "client_id" => STRING }),
           responses: { 200 => AUTH_TOKEN_RESPONSE, 403 => ERROR, 422 => ERROR }
  register "Api::V1::UsersController#reset_password",
           request: strict_object(required: %w[email], properties: { "email" => STRING }),
           responses: { 200 => MESSAGE }
  register "Api::V1::UsersController#change_password",
           request: strict_object(required: %w[new_password reset_token], 
properties: { "new_password" => STRING, "reset_token" => STRING, "user" => ANY_OBJECT }),
           responses: { 200 => MESSAGE, 404 => ERROR }
  register "Api::V1::UsersController#current_user_details", request: NO_PARAMS, responses: { 200 => USER_ENVELOPE, 401 => AUTH_ERROR }
  register "Api::V1::UsersController#edit_user",
           request: strict_object(required: [], properties: { "name" => STRING_OR_NULL }),
           responses: { 200 => USER_ENVELOPE, 401 => AUTH_ERROR }
  register "Api::V1::UsersController#remove_user", request: NO_PARAMS, responses: { 200 => MESSAGE, 401 => AUTH_ERROR }
  register "Api::V1::UsersController#otp_enabled",
           request: strict_object(required: [], properties: { "email" => STRING_OR_NULL }),
           responses: { 200 => strict_object(required: %w[otp_enabled], properties: { "otp_enabled" => { "type" => "boolean" } }), 401 => AUTH_ERROR }
  register "Api::V1::UsersController#otp_qr", request: NO_PARAMS, responses: { 200 => NON_JSON_RESPONSE, 401 => AUTH_ERROR }
  register "Api::V1::UsersController#set_2fa_enabled",
           request: strict_object(required: %w[enable_2fa otp_code], properties: { "enable_2fa" => BOOL, "otp_code" => STRING }),
           responses: { 200 => USER_ENVELOPE, 403 => ERROR, 401 => AUTH_ERROR }

  # Instances
  register "Api::V1::InstancesController#create_instance",
           request: strict_object(required: %w[name], properties: { "name" => STRING, "members" => ARRAY_OR_NULL }),
           responses: { 200 => INSTANCE_ENVELOPE, 400 => ERROR, 401 => AUTH_ERROR }
  register "Api::V1::InstancesController#delete_instance", request: NO_PARAMS, responses: { 200 => MESSAGE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::InstancesController#set_revenue_collection_enabled",
           request: strict_object(required: %w[revenue_collection_enabled], properties: { "revenue_collection_enabled" => BOOL }),
           responses: { 200 => INSTANCE_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::InstancesController#current_user_instances", request: NO_PARAMS, responses: { 200 => INSTANCES_ENVELOPE, 401 => AUTH_ERROR }
  register "Api::V1::InstancesController#edit_instance",
           request: strict_object(required: [], properties: { "name" => STRING_OR_NULL }),
           responses: { 200 => INSTANCE_PROJECT_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::InstancesController#members_for_instance", request: NO_PARAMS, responses: { 200 => MEMBERS_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::InstancesController#add_member_to_instance",
           request: strict_object(required: %w[email role], properties: { "email" => STRING, "role" => STRING }),
           responses: { 200 => ROLE_ADDED_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 422 => ERROR }
  register "Api::V1::InstancesController#remove_member_from_instance",
           request: strict_object(required: %w[email], properties: { "email" => STRING }),
           responses: { 200 => MESSAGE, 401 => AUTH_ERROR, 403 => ERROR }
  register "Api::V1::InstancesController#user_role_for_instance", request: NO_PARAMS, responses: { 200 => ROLE_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::InstancesController#instance_details", request: NO_PARAMS, responses: { 200 => INSTANCE_SETUP_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::InstancesController#dismiss_get_started", request: NO_PARAMS, responses: { 200 => INSTANCE_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::InstancesController#setup_progress",
           request: strict_object(required: [], properties: { "category" => STRING_OR_NULL }),
           responses: { 200 => SETUP_STEPS_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::InstancesController#complete_setup_step",
           request: strict_object(required: %w[category step_identifier], properties: { "category" => STRING, "step_identifier" => STRING }),
           responses: { 200 => SETUP_STEP_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR, 
422 => strict_object(required: %w[errors], properties: { "errors" => ARRAY }) }

  # Domains
  register "Api::V1::DomainsController#current_project_domain", request: NO_PARAMS, responses: { 200 => DOMAIN_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR }
  register "Api::V1::DomainsController#domain_defaults", request: NO_PARAMS, responses: { 200 => DOMAIN_DEFAULTS_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR }
  register "Api::V1::DomainsController#domain_is_available",
           request: strict_object(required: %w[subdomain], properties: { "subdomain" => STRING }),
           responses: { 200 => AVAILABLE_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR }
  register "Api::V1::DomainsController#set_google_tracking_id",
           request: strict_object(required: [], properties: { "google_tracking_id" => STRING_OR_NULL }),
           responses: { 200 => DOMAIN_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR }
  register "Api::V1::DomainsController#set_project_domain",
           request: strict_object(required: [], 
properties: { "generic_title" => STRING_OR_NULL, "generic_subtitle" => STRING_OR_NULL, "subdomain" => STRING_OR_NULL, "generic_image_url" => STRING_OR_NULL, 
"generic_image" => JSON_VALUE }),
           responses: { 200 => DOMAIN_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 422 => ERROR }

  # Configurations and redirects
  register "Api::V1::ConfigurationsController#current_project_configurations", request: NO_PARAMS, responses: { 200 => CONFIGURATIONS_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR }
  register "Api::V1::ConfigurationsController#set_ios_configuration",
           request: strict_object(required: %w[enabled], 
properties: { "enabled" => BOOL, "bundle_id" => STRING_OR_NULL, "app_prefix" => STRING_OR_NULL, "tablet_enabled" => BOOL_OR_NULL }),
           responses: { 200 => CONFIG_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 422 => ERROR }
  register "Api::V1::ConfigurationsController#set_ios_push_configuration",
           request: strict_object(required: [], properties: { "push_certificate_password" => STRING_OR_NULL, "push_certificate" => JSON_VALUE }),
           responses: { 200 => CONFIG_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 422 => ERROR }
  register "Api::V1::ConfigurationsController#set_android_configuration",
           request: strict_object(required: %w[enabled], 
properties: { "enabled" => BOOL, "identifier" => STRING_OR_NULL, "sha256s" => { "type" => %w[array string null] }, "tablet_enabled" => BOOL_OR_NULL }),
           responses: { 200 => CONFIG_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 422 => ERROR }
  register "Api::V1::ConfigurationsController#set_android_push_configuration",
           request: strict_object(required: [], properties: { "firebase_project_id" => STRING_OR_NULL, "push_certificate" => JSON_VALUE }),
           responses: { 200 => CONFIG_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 422 => ERROR }
  register "Api::V1::ConfigurationsController#set_android_api_access_key",
           request: strict_object(required: [], properties: { "file" => JSON_VALUE }),
           responses: { 200 => CONFIG_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 422 => ERROR }
  register "Api::V1::ConfigurationsController#set_ios_api_access_key",
           request: strict_object(required: [], properties: { "file" => JSON_VALUE, "key_id" => STRING_OR_NULL, "issuer_id" => STRING_OR_NULL }),
           responses: { 200 => CONFIG_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 422 => ERROR }
  register "Api::V1::ConfigurationsController#set_desktop_configuration",
           request: strict_object(required: %w[enabled], 
properties: { "enabled" => BOOL, "generated_page" => BOOL_OR_NULL, "fallback_url" => STRING_OR_NULL, "mac_uri" => STRING_OR_NULL, 
"windows_uri" => STRING_OR_NULL, "mac_enabled" => BOOL_OR_NULL, "windows_enabled" => BOOL_OR_NULL }),
           responses: { 200 => CONFIG_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 422 => ERROR }
  register "Api::V1::ConfigurationsController#set_web_configuration",
           request: strict_object(required: %w[enabled], properties: { "enabled" => BOOL, "domains" => ARRAY_OR_NULL }),
           responses: { 200 => CONFIG_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 422 => ERROR }
  %w[
    Api::V1::ConfigurationsController#remove_ios_configuration
    Api::V1::ConfigurationsController#remove_android_configuration
    Api::V1::ConfigurationsController#remove_desktop_configuration
    Api::V1::ConfigurationsController#remove_web_configuration
  ].each { |action| register action, request: NO_PARAMS, responses: { 200 => CONFIG_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR } }
  register "Api::V1::ConfigurationsController#google_configuration_script", request: NO_PARAMS, responses: { 200 => NON_JSON_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR }

  register "Api::V1::RedirectsController#redirect_config", request: NO_PARAMS, responses: { 200 => REDIRECT_CONFIG_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR }
  register "Api::V1::RedirectsController#set_redirect_config",
           request: strict_object(required: [], 
properties: { "default_fallback" => STRING_OR_NULL, "show_preview_android" => BOOL, "show_preview_ios" => BOOL }),
           responses: { 200 => REDIRECT_CONFIG_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 422 => ERROR }
  register "Api::V1::RedirectsController#set_redirect",
           request: strict_object(required: %w[platform variation], 
properties: { "platform" => STRING, "variation" => STRING, "appstore" => BOOL, "fallback_url" => STRING_OR_NULL, "enabled" => BOOL }),
           responses: { 200 => REDIRECT_CONFIG_AS_CONFIG_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 422 => ERROR }

  # Campaigns, links, dashboard, events.
  %w[
    Api::V1::CampaignsController#current_project_campaigns
    Api::V1::CampaignsController#current_project_campaigns_v2
    Api::V1::LinksController#current_project_links
    Api::V1::LinksController#current_project_links_v2
  ].each do |action| 
    register action, request: SEARCH_REQUEST, 
  responses: { 200 => PAGINATED_RESPONSE, 400 => RAILS_EXCEPTION_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  end
  register "Api::V1::CampaignsController#create", request: strict_object(required: %w[name], properties: { "name" => STRING }), responses: { 200 => CAMPAIGN_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::CampaignsController#update", request: strict_object(required: [], properties: { "campaign_id" => ID, "name" => STRING_OR_NULL }), responses: { 200 => CAMPAIGN_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::CampaignsController#archive", request: strict_object(required: [], properties: { "campaign_id" => ID }), responses: { 200 => CAMPAIGN_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::CampaignsController#metrics_for_overview", request: SEARCH_REQUEST, responses: { 200 => EVENT_TIMESERIES_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR }

  register "Api::V1::LinksController#create_link", request: DASHBOARD_LINK_REQUEST, responses: { 200 => LINK_ENVELOPE, 400 => ERROR, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR, 422 => RAILS_EXCEPTION_RESPONSE }
  register "Api::V1::LinksController#update_link", request: DASHBOARD_LINK_REQUEST, responses: { 200 => LINK_ENVELOPE, 400 => ERROR, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR, 422 => ERROR }
  register "Api::V1::LinksController#remove_link", request: NO_PARAMS, responses: { 200 => MESSAGE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::LinksController#is_path_available", request: strict_object(required: %w[path], properties: { "path" => STRING }), responses: { 200 => AVAILABLE_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR }
  register "Api::V1::LinksController#generate_path", request: NO_PARAMS, responses: { 200 => GENERATED_PATH_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR }
  register "Api::V1::LinksController#links_by_ids", request: strict_object(required: %w[ids], properties: { "ids" => ARRAY }), responses: { 200 => LINKS_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR }

  register "Api::V1::DashboardController#metrics_overview", request: SEARCH_REQUEST, responses: { 200 => strict_object(required: %w[metrics], properties: { "metrics" => DASHBOARD_METRICS_RESPONSE }), 401 => AUTH_ERROR, 403 => ERROR }
  register "Api::V1::DashboardController#links_views", request: SEARCH_REQUEST, responses: { 200 => strict_object(required: %w[metrics], properties: { "metrics" => DATE_NUMBER_MAP_RESPONSE }), 401 => AUTH_ERROR, 403 => ERROR }
  register "Api::V1::EventsController#events_for_search_params", request: SEARCH_REQUEST, responses: { 200 => strict_object(required: %w[metrics], properties: { "metrics" => LINK_EVENT_METRICS_MAP }), 401 => AUTH_ERROR, 403 => ERROR }
  register "Api::V1::DashboardController#best_performing_links", request: SEARCH_REQUEST, responses: { 200 => TOP_LINKS_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR }
  register "Api::V1::EventsController#events_sorted_by_param", request: SEARCH_REQUEST, responses: { 200 => EVENTS_SORTED_RESPONSE, 400 => RAILS_EXCEPTION_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR }
  register "Api::V1::EventsController#events_for_overview", request: SEARCH_REQUEST, responses: { 200 => EVENT_TIMESERIES_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR }
  register "Api::V1::EventsController#events_for_payment_screen", request: SEARCH_REQUEST, responses: { 200 => PAYMENT_SCREEN_EVENTS_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::EventsController#metrics_values", request: NO_PARAMS, responses: { 200 => METRICS_VALUES_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR }

  # Notifications
  register "Api::V1::NotificationsController#test", request: NO_PARAMS,
           responses: { 200 => strict_object(required: %w[notifications], properties: { "notifications" => STRING }), 401 => AUTH_ERROR }
  register "Api::V1::NotificationsController#create",
           request: strict_object(required: [], 
properties: { "title" => STRING_OR_NULL, "html" => STRING_OR_NULL, "subtitle" => STRING_OR_NULL, "auto_display" => BOOL_OR_NULL, "send_push" => BOOL_OR_NULL, 
"new_users" => BOOL_OR_NULL, "existing_users" => BOOL_OR_NULL, "platforms" => ARRAY_OR_NULL }),
           responses: { 200 => NOTIFICATION_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::NotificationsController#notifications", request: SEARCH_REQUEST, responses: { 200 => PAGINATED_RESPONSE, 400 => RAILS_EXCEPTION_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::NotificationsController#archive_notification", request: NO_PARAMS, responses: { 200 => NOTIFICATIONS_ARCHIVE_ENVELOPE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR, 422 => ERROR }

  # Payments/admin/export/diagnostics/webhooks/SSO/IAP/purchases.
  %w[
    Api::V1::PaymentsController#create_subscription_session
    Api::V1::PaymentsController#stripe_dashboard_url
  ].each { |action| register action, request: NO_PARAMS, responses: { 200 => URL_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 422 => ERROR } }
  register "Api::V1::PaymentsController#cancel_subscription", request: NO_PARAMS, responses: { 200 => RESULT_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  %w[
    Api::V1::PaymentsController#subscription_details
  ].each do |action| 
    register action, request: SEARCH_REQUEST, 
  responses: { 200 => BILLING_SUBSCRIPTION_DETAILS_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  end
  register "Api::V1::PaymentsController#current_mau", request: SEARCH_REQUEST, responses: { 200 => CURRENT_MAU_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::PaymentsController#current_usage", request: SEARCH_REQUEST, responses: { 200 => BILLING_USAGE_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::PurchasesController#purchases", request: SEARCH_REQUEST, responses: { 200 => PURCHASES_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::PurchasesController#revenue_metrics", request: SEARCH_REQUEST, responses: { 200 => REVENUE_METRICS_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }

  register "Api::V1::ExportController#export_link_data",
           request: SEARCH_REQUEST,
           responses: { 202 => MESSAGE, 400 => ERROR, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::ExportController#export_usage_data",
           request: strict_object(required: [], properties: DATE_FILTERS.merge("instance_id" => STRING_OR_NULL)),
           responses: { 202 => MESSAGE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::DiagnosticsController#test_logs",
           request: strict_object(required: [], 
properties: { "level" => STRING_OR_NULL, "message" => STRING_OR_NULL, "count" => { "type" => %w[integer string null] }, "api_key" => STRING_OR_NULL }),
           responses: { 200 => DIAGNOSTIC_LOGS_RESPONSE, 401 => AUTH_ERROR }
  register "Api::V1::DiagnosticsController#test_exception",
           request: strict_object(required: [], properties: { "type" => STRING_OR_NULL, "message" => STRING_OR_NULL }),
           responses: { 401 => AUTH_ERROR, 404 => { "oneOf" => [ERROR, RAILS_EXCEPTION_RESPONSE] }, 500 => RAILS_EXCEPTION_RESPONSE }
  register "Api::V1::DiagnosticsController#test_diagnostics",
           request: strict_object(required: [], 
properties: { "iterations" => { "type" => %w[integer string null] }, "include_slow" => BOOL_OR_NULL, "cleanup" => BOOL_OR_NULL }),
           responses: { 200 => DIAGNOSTICS_RESPONSE, 401 => AUTH_ERROR, 
500 => strict_object(required: %w[error backtrace timestamp], properties: { "error" => STRING, "backtrace" => ARRAY, "timestamp" => STRING }) }
  register "Api::V1::Identity::Sso::SessionsController#passthru",
           request: strict_object(required: [], properties: { "provider" => STRING_OR_NULL }),
           responses: { 200 => SSO_REDIRECT_URL_RESPONSE, 422 => ERROR }
  register "Api::V1::Identity::Sso::SessionsController#omniauth_failure",
           request: NO_PARAMS,
           responses: { 302 => REDIRECT_RESPONSE }
  register "Api::V1::Identity::Sso::SessionsController#create",
           request: strict_object(required: [], properties: { "state" => STRING_OR_NULL }),
           responses: { 302 => REDIRECT_RESPONSE, 422 => ERROR }
  register "Api::V1::Identity::Sso::TokensController#refresh_token",
           request: strict_object(required: [], properties: { "refresh_token" => STRING_OR_NULL }),
           responses: { 200 => SSO_TOKEN_RESPONSE, 400 => NON_JSON_RESPONSE, 401 => ERROR }
  %w[
    Api::V1::IapController#apple_prod
    Api::V1::IapController#apple_test
    Api::V1::IapController#google_handling
  ].each do |action| 
    register action, request: DYNAMIC_OBJECT_RESPONSE, 
  responses: { 200 => DYNAMIC_OBJECT_RESPONSE, 400 => ERROR, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR, 422 => ERROR, 500 => ERROR }
  end

  register "Api::V1::AdminController#create_enterprise_subscription",
           request: strict_object(required: [], 
properties: { "instance_id" => ID, "start_date" => STRING_OR_NULL, "end_date" => STRING_OR_NULL, "total_maus" => { "type" => %w[integer string null] }, 
"active" => BOOL_OR_NULL }),
           responses: { 201 => ADMIN_SUBSCRIPTION_RESPONSE, 403 => ERROR, 404 => ERROR, 422 => ERROR_WITH_MESSAGE }
  register "Api::V1::AdminController#update_enterprise_subscription",
           request: strict_object(required: %w[id], 
properties: { "id" => ID, "start_date" => STRING_OR_NULL, "end_date" => STRING_OR_NULL, "total_maus" => { "type" => %w[integer string null] }, 
"active" => BOOL_OR_NULL }),
           responses: { 200 => ADMIN_SUBSCRIPTION_RESPONSE, 403 => ERROR, 404 => ERROR, 422 => ERROR_WITH_MESSAGE }
  register "Api::V1::AdminController#migrate_firebase_links",
           request: strict_object(required: [], 
properties: { "file" => JSON_VALUE, "project_id" => ID, "deeplink_prefix" => STRING_OR_NULL, "short_link_prefix" => STRING_OR_NULL }),
           responses: { 200 => FIREBASE_MIGRATION_RESPONSE, 403 => ERROR, 404 => ERROR, 422 => ERROR }
  register "Api::V1::AdminController#flush_events",
           request: strict_object(required: [], properties: { "aggregate_days" => { "type" => %w[integer string null] } }),
           responses: { 200 => FLUSH_EVENTS_RESPONSE, 403 => ERROR, 500 => ERROR }

  register "Api::V1::AutomationController#metrics_for_user",
           request: strict_object(required: %w[key vendor_id test], 
properties: { "key" => STRING, "vendor_id" => STRING, "test" => BOOL, "automation" => DYNAMIC_OBJECT_RESPONSE }),
           responses: { 
200 => strict_object(required: %w[visitor metrics aggregated_metrics number_of_generated_links], 
properties: { "visitor" => AUTOMATION_VISITOR_RESPONSE, "metrics" => { "type" => %w[object null] }, "aggregated_metrics" => { "type" => %w[object null] }, 
"number_of_generated_links" => { "type" => "integer" } }), 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  register "Api::V1::AutomationController#details_for_link",
           request: strict_object(required: %w[key path test], 
properties: { "key" => STRING, "path" => STRING, "test" => BOOL, "automation" => DYNAMIC_OBJECT_RESPONSE }),
           responses: { 
200 => strict_object(required: %w[link metrics], 
properties: { "link" => LINK_RESPONSE.merge("type" => %w[object null]), 
"metrics" => { "type" => %w[object null] } }), 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }

  register "Api::V1::WebhooksController#stripe_webhook", request: DYNAMIC_OBJECT_RESPONSE, responses: { 200 => MESSAGE, 400 => ERROR, 500 => ERROR }
  register "Api::V1::WebhooksController#send_stripe_quotas", request: NO_PARAMS, responses: { 200 => MESSAGE, 403 => ERROR }

  %w[
    Api::V1::VisitorsController#visitors
    Api::V1::VisitorsController#aggregated_visitors
  ].each { |action| register action, request: SEARCH_REQUEST, responses: { 200 => VISITOR_QUERY_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR } }
  # Legacy metrics endpoints return a flat envelope (page serialized as a string).
  LEGACY_VISITOR_METRICS_RESPONSE = strict_object(
    required: %w[metrics page total_pages per_page total_entries],
    properties: {
      "metrics" => ARRAY,
      "page" => { "type" => %w[integer string] },
      "total_pages" => { "type" => "integer" },
      "per_page" => { "type" => "integer" },
      "total_entries" => { "type" => "integer" }
    }
  )
  LEGACY_VISITOR_METRICS_REQUEST = strict_object(
    required: [],
    properties: SEARCH_FILTERS.merge("visitor_id" => { "type" => %w[integer string null] })
  )
  %w[
    Api::V1::VisitorsController#visitor_metrics_for_search_params
    Api::V1::VisitorsController#aggregated_visitor_metrics_for_search_params
  ].each do |action| 
    register action, request: LEGACY_VISITOR_METRICS_REQUEST, 
  responses: { 200 => LEGACY_VISITOR_METRICS_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
  end
  register "Api::V1::VisitorsController#visitor_details", request: SEARCH_REQUEST, responses: { 200 => VISITOR_DETAIL_RESPONSE, 401 => AUTH_ERROR, 403 => ERROR, 404 => ERROR }
end
