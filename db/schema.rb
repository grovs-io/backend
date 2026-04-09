# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_09_054757) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "actions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "device_id", null: false
    t.boolean "handled", default: false
    t.bigint "link_id", null: false
    t.datetime "updated_at", null: false
    t.index ["device_id"], name: "index_actions_on_device_id"
    t.index ["link_id"], name: "index_actions_on_link_id"
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum", null: false
    t.string "content_type"
    t.datetime "created_at", precision: nil, null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "android_configurations", force: :cascade do |t|
    t.bigint "application_id"
    t.datetime "created_at", null: false
    t.string "identifier", null: false
    t.text "sha256s", default: [], array: true
    t.boolean "tablet_enabled", default: false
    t.datetime "updated_at", null: false
    t.index ["application_id"], name: "index_android_configurations_on_application_id", unique: true
  end

  create_table "android_push_configurations", force: :cascade do |t|
    t.bigint "android_configuration_id", null: false
    t.datetime "created_at", null: false
    t.string "firebase_project_id"
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["android_configuration_id"], name: "index_android_push_configurations_on_android_configuration_id"
  end

  create_table "android_server_api_keys", force: :cascade do |t|
    t.bigint "android_configuration_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["android_configuration_id"], name: "index_android_server_api_keys_on_android_configuration_id"
  end

  create_table "applications", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true
    t.bigint "instance_id"
    t.string "platform", null: false
    t.datetime "updated_at", null: false
    t.index ["instance_id"], name: "index_applications_on_instance_id"
  end

  create_table "campaigns", force: :cascade do |t|
    t.boolean "archived", default: false
    t.datetime "created_at", null: false
    t.string "name"
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_campaigns_on_project_id"
  end

  create_table "custom_redirects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "link_id", null: false
    t.boolean "open_app_if_installed", default: true, null: false
    t.string "platform", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["link_id", "platform"], name: "index_custom_redirects_on_link_id_and_platform", unique: true
    t.index ["link_id"], name: "index_custom_redirects_on_link_id"
  end

  create_table "daily_project_metrics", force: :cascade do |t|
    t.integer "app_opens"
    t.bigint "cancellations", default: 0
    t.datetime "created_at", null: false
    t.date "event_date", null: false
    t.bigint "first_time_purchases", default: 0
    t.integer "first_time_visitors", default: 0, null: false
    t.integer "installs", default: 0, null: false
    t.integer "link_views", default: 0, null: false
    t.integer "new_users", default: 0, null: false
    t.integer "opens", default: 0, null: false
    t.integer "organic_users", default: 0, null: false
    t.string "platform", default: "web", null: false
    t.integer "project_id", null: false
    t.integer "referred_users", default: 0, null: false
    t.integer "reinstalls", default: 0, null: false
    t.integer "returning_users", default: 0, null: false
    t.bigint "revenue", default: 0
    t.bigint "units_sold", default: 0
    t.datetime "updated_at", null: false
    t.integer "views", default: 0, null: false
    t.index ["event_date"], name: "index_daily_project_metrics_on_event_date"
    t.index ["project_id", "event_date", "platform"], name: "idx_dpm_on_project_date_platform", unique: true
  end

  create_table "desktop_configurations", force: :cascade do |t|
    t.bigint "application_id"
    t.datetime "created_at", null: false
    t.string "fallback_url"
    t.boolean "generated_page", default: true
    t.boolean "mac_enabled", default: false
    t.string "mac_uri"
    t.datetime "updated_at", null: false
    t.boolean "windows_enabled", default: false
    t.string "windows_uri"
    t.index ["application_id"], name: "index_desktop_configurations_on_application_id", unique: true
  end

  create_table "device_product_purchases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "device_id", null: false
    t.string "product_id", null: false
    t.bigint "project_id", null: false
    t.index ["device_id", "project_id", "product_id"], name: "idx_device_product_purchases_unique", unique: true
  end

  create_table "devices", force: :cascade do |t|
    t.string "app_version"
    t.string "build"
    t.datetime "created_at", null: false
    t.string "ip", null: false
    t.string "language"
    t.string "model"
    t.string "platform"
    t.string "push_token"
    t.string "remote_ip", null: false
    t.integer "screen_height"
    t.integer "screen_width"
    t.string "timezone"
    t.datetime "updated_at", null: false
    t.string "user_agent", null: false
    t.string "vendor"
    t.string "webgl_renderer"
    t.string "webgl_vendor"
    t.index ["id"], name: "idx_devices_id_with_platform", include: ["platform"]
    t.index ["ip"], name: "index_devices_on_ip"
    t.index ["remote_ip"], name: "index_devices_on_remote_ip"
    t.index ["updated_at"], name: "index_devices_on_updated_at"
    t.index ["vendor"], name: "index_devices_on_vendor"
  end

  create_table "diagnostics_logs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "duration_ms"
    t.string "hostname"
    t.string "operation", null: false
    t.text "payload"
    t.string "test_key", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_diagnostics_logs_on_created_at"
    t.index ["test_key"], name: "index_diagnostics_logs_on_test_key"
  end

  create_table "domains", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "domain", null: false
    t.string "generic_image_url"
    t.string "generic_subtitle"
    t.string "generic_title"
    t.string "google_tracking_id"
    t.bigint "project_id"
    t.string "subdomain"
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_domains_on_domain"
    t.index ["project_id"], name: "index_domains_on_project_id"
  end

  create_table "downloadable_files", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.datetime "updated_at", null: false
  end

  create_table "enterprise_subscriptions", force: :cascade do |t|
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "end_date"
    t.integer "instance_id", null: false
    t.datetime "start_date"
    t.integer "total_maus"
    t.datetime "updated_at", null: false
    t.index ["instance_id"], name: "index_enterprise_subscriptions_on_instance_id"
  end

  create_table "events", force: :cascade do |t|
    t.string "app_version"
    t.string "build"
    t.datetime "created_at", null: false
    t.json "data"
    t.bigint "device_id", null: false
    t.bigint "engagement_time"
    t.string "event", null: false
    t.string "ip"
    t.bigint "link_id"
    t.string "path"
    t.string "platform"
    t.boolean "processed", default: false, null: false
    t.bigint "project_id", null: false
    t.string "remote_ip"
    t.datetime "updated_at", null: false
    t.string "vendor_id"
    t.index ["created_at"], name: "index_events_on_created_at"
    t.index ["device_id"], name: "index_events_on_device_id"
    t.index ["link_id"], name: "index_events_on_link_id"
    t.index ["project_id", "device_id", "created_at"], name: "index_events_on_project_id_and_device_id_and_created_at"
    t.index ["project_id"], name: "index_events_on_project_id"
    t.index ["vendor_id"], name: "index_events_on_vendor_id"
  end

  create_table "failed_purchase_jobs", force: :cascade do |t|
    t.jsonb "arguments", default: [], null: false
    t.text "backtrace"
    t.datetime "created_at", null: false
    t.string "error_class"
    t.text "error_message"
    t.datetime "failed_at", null: false
    t.string "job_class", null: false
    t.bigint "project_id"
    t.bigint "purchase_event_id"
    t.datetime "retried_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_failed_purchase_jobs_on_project_id"
    t.index ["purchase_event_id"], name: "index_failed_purchase_jobs_on_purchase_event_id"
    t.index ["status"], name: "index_failed_purchase_jobs_on_status"
  end

  create_table "iap_webhook_messages", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "instance_id"
    t.string "notification_type"
    t.text "payload", null: false
    t.bigint "project_id"
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.index ["instance_id"], name: "index_iap_webhook_messages_on_instance_id"
    t.index ["project_id"], name: "index_iap_webhook_messages_on_project_id"
  end

  create_table "in_app_product_daily_statistics", force: :cascade do |t|
    t.integer "canceled_events", default: 0, null: false
    t.datetime "created_at", null: false
    t.bigint "device_revenue", default: 0, null: false
    t.date "event_date", null: false
    t.integer "first_time_purchases"
    t.bigint "in_app_product_id", null: false
    t.string "platform", default: "web", null: false
    t.bigint "project_id", null: false
    t.integer "purchase_events", default: 0, null: false
    t.integer "repeat_purchases", default: 0, null: false
    t.bigint "revenue", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["event_date"], name: "idx_iapds_event_date"
    t.index ["in_app_product_id", "event_date", "platform"], name: "idx_iapds_unique_product_event_date_platform", unique: true
    t.index ["project_id", "event_date"], name: "idx_iapds_project_event_date"
  end

  create_table "in_app_products", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "platform", null: false
    t.string "product_id", null: false
    t.bigint "project_id", null: false
    t.integer "unique_purchasing_devices", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "platform", "product_id"], name: "idx_in_app_products_on_project_platform_product", unique: true
    t.index ["project_id", "product_id"], name: "index_in_app_products_on_project_id_and_product_id"
  end

  create_table "installed_apps", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "device_id", null: false
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["device_id", "project_id"], name: "index_installed_apps_on_device_id_and_project_id", unique: true
    t.index ["device_id"], name: "index_installed_apps_on_device_id"
    t.index ["project_id"], name: "index_installed_apps_on_project_id"
  end

  create_table "instance_roles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "instance_id"
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["instance_id"], name: "index_instance_roles_on_instance_id"
    t.index ["user_id"], name: "index_instance_roles_on_user_id"
  end

  create_table "instances", force: :cascade do |t|
    t.string "api_key", null: false
    t.datetime "created_at", null: false
    t.boolean "get_started_dismissed", default: false
    t.datetime "last_quota_exceeded_sent_at"
    t.datetime "last_quota_warning_sent_at"
    t.boolean "quota_exceeded", default: false
    t.boolean "revenue_collection_enabled", default: false, null: false
    t.datetime "updated_at", null: false
    t.string "uri_scheme", null: false
    t.index ["api_key"], name: "index_instances_on_api_key", unique: true
    t.index ["uri_scheme"], name: "index_instances_on_uri_scheme"
  end

  create_table "ios_configurations", force: :cascade do |t|
    t.string "app_prefix", null: false
    t.bigint "application_id"
    t.string "bundle_id"
    t.datetime "created_at", null: false
    t.boolean "tablet_enabled", default: false
    t.datetime "updated_at", null: false
    t.index ["application_id"], name: "index_ios_configurations_on_application_id", unique: true
  end

  create_table "ios_push_configurations", force: :cascade do |t|
    t.string "certificate_password"
    t.datetime "created_at", null: false
    t.bigint "ios_configuration_id", null: false
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["ios_configuration_id"], name: "index_ios_push_configurations_on_ios_configuration_id"
  end

  create_table "ios_server_api_keys", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "filename"
    t.bigint "ios_configuration_id", null: false
    t.string "issuer_id", null: false
    t.string "key_id", null: false
    t.text "private_key", null: false
    t.datetime "updated_at", null: false
    t.index ["ios_configuration_id"], name: "index_ios_server_api_keys_on_ios_configuration_id"
  end

  create_table "link_daily_statistics", id: false, force: :cascade do |t|
    t.integer "app_opens", default: 0, null: false
    t.datetime "created_at", null: false
    t.date "event_date", null: false
    t.bigserial "id", null: false
    t.integer "installs", default: 0, null: false
    t.bigint "link_id", null: false
    t.integer "opens", default: 0, null: false
    t.string "platform", default: "web", null: false
    t.integer "project_id"
    t.integer "reactivations", default: 0, null: false
    t.integer "reinstalls", default: 0, null: false
    t.bigint "revenue", default: 0, null: false
    t.bigint "time_spent", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_referred", default: 0, null: false
    t.integer "views", default: 0, null: false
    t.index ["event_date", "project_id", "platform"], name: "index_lds_on_date_project_platform"
    t.index ["link_id"], name: "index_link_daily_statistics_on_link_id"
    t.index ["project_id", "link_id", "event_date", "platform"], name: "link_daily_statistics_pkey", unique: true
  end

  create_table "links", force: :cascade do |t|
    t.boolean "active", default: true
    t.string "ads_platform"
    t.bigint "campaign_id"
    t.datetime "created_at", null: false
    t.json "data"
    t.bigint "domain_id"
    t.string "generated_from_platform", null: false
    t.string "image_url"
    t.string "name"
    t.string "path", null: false
    t.bigint "redirect_config_id", null: false
    t.boolean "sdk_generated", default: false
    t.boolean "show_preview_android"
    t.boolean "show_preview_ios"
    t.string "subtitle"
    t.text "tags", default: [], array: true
    t.string "title"
    t.string "tracking_campaign"
    t.string "tracking_medium"
    t.string "tracking_source"
    t.datetime "updated_at", null: false
    t.bigint "visitor_id"
    t.index ["campaign_id"], name: "index_links_on_campaign_id"
    t.index ["domain_id"], name: "index_links_on_domain_id"
    t.index ["path"], name: "index_links_on_path"
    t.index ["redirect_config_id"], name: "index_links_on_redirect_config_id"
    t.index ["visitor_id"], name: "index_links_on_visitor_id"
  end

  create_table "mcp_authorization_codes", force: :cascade do |t|
    t.string "client_id", default: "", null: false
    t.string "code", null: false
    t.string "code_challenge"
    t.string "code_challenge_method"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "redirect_uri", null: false
    t.string "scope"
    t.string "state"
    t.datetime "updated_at", null: false
    t.datetime "used_at"
    t.bigint "user_id", null: false
    t.index ["code"], name: "index_mcp_authorization_codes_on_code", unique: true
    t.index ["expires_at"], name: "index_mcp_authorization_codes_on_expires_at"
    t.index ["user_id"], name: "index_mcp_authorization_codes_on_user_id"
  end

  create_table "mcp_clients", force: :cascade do |t|
    t.string "application_type", default: "native"
    t.string "client_id", null: false
    t.string "client_name", null: false
    t.string "client_uri"
    t.datetime "created_at", null: false
    t.string "grant_types", default: "authorization_code"
    t.string "logo_uri"
    t.jsonb "redirect_uris", default: [], null: false
    t.string "response_types", default: "code"
    t.string "token_endpoint_auth_method", default: "none"
    t.datetime "updated_at", null: false
    t.index ["client_id"], name: "index_mcp_clients_on_client_id", unique: true
  end

  create_table "mcp_tokens", force: :cascade do |t|
    t.string "client_id"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.string "refresh_token_digest"
    t.datetime "revoked_at"
    t.string "scope"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["client_id"], name: "index_mcp_tokens_on_client_id"
    t.index ["expires_at"], name: "index_mcp_tokens_on_expires_at"
    t.index ["refresh_token_digest"], name: "index_mcp_tokens_on_refresh_token_digest", unique: true, where: "(refresh_token_digest IS NOT NULL)"
    t.index ["token_digest"], name: "index_mcp_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_mcp_tokens_on_user_id"
  end

  create_table "notification_messages", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "notification_id", null: false
    t.boolean "read", default: false
    t.datetime "updated_at", null: false
    t.bigint "visitor_id", null: false
    t.index ["notification_id", "read"], name: "idx_notification_messages_on_notification_and_read"
    t.index ["notification_id"], name: "index_notification_messages_on_notification_id"
    t.index ["read"], name: "index_notification_messages_on_read"
    t.index ["visitor_id"], name: "index_notification_messages_on_visitor_id"
  end

  create_table "notification_targets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "existing_users", default: false
    t.boolean "new_users", default: false
    t.bigint "notification_id", null: false
    t.string "platforms", default: [], array: true
    t.datetime "updated_at", null: false
    t.index ["notification_id"], name: "index_notification_targets_on_notification_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.boolean "archived", default: false
    t.boolean "auto_display", default: false
    t.datetime "created_at", null: false
    t.text "html"
    t.bigint "project_id"
    t.boolean "send_push", default: false
    t.string "subtitle"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["auto_display"], name: "index_notifications_on_auto_display"
    t.index ["project_id"], name: "index_notifications_on_project_id"
  end

  create_table "oauth_access_tokens", force: :cascade do |t|
    t.bigint "application_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.integer "expires_in"
    t.string "previous_refresh_token", default: "", null: false
    t.string "refresh_token"
    t.bigint "resource_owner_id"
    t.datetime "revoked_at", precision: nil
    t.string "scopes"
    t.string "token", null: false
    t.index ["application_id"], name: "index_oauth_access_tokens_on_application_id"
    t.index ["refresh_token"], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index ["resource_owner_id"], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", force: :cascade do |t|
    t.boolean "confidential", default: true, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "redirect_uri"
    t.string "scopes", default: "", null: false
    t.string "secret", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.index ["uid"], name: "index_oauth_applications_on_uid", unique: true
  end

  create_table "project_daily_active_users", force: :cascade do |t|
    t.integer "active_users", default: 0, null: false
    t.datetime "created_at", null: false
    t.date "event_date"
    t.string "platform", default: "web", null: false
    t.bigint "project_id"
    t.datetime "updated_at", null: false
    t.index ["project_id", "event_date", "platform"], name: "idx_project_dau_on_project_date_platform", unique: true
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "identifier", null: false
    t.bigint "instance_id"
    t.string "name", null: false
    t.boolean "test", default: false
    t.datetime "updated_at", null: false
    t.index ["identifier"], name: "index_projects_on_identifier", unique: true
    t.index ["instance_id"], name: "index_projects_on_instance_id"
  end

  create_table "purchase_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency"
    t.datetime "date"
    t.bigint "device_id"
    t.string "event_type"
    t.datetime "expires_date"
    t.string "identifier"
    t.bigint "link_id"
    t.string "order_id"
    t.string "original_transaction_id"
    t.bigint "price_cents"
    t.boolean "processed", default: false, null: false
    t.string "product_id"
    t.bigint "project_id"
    t.string "purchase_type"
    t.integer "quantity", default: 1, null: false
    t.boolean "store", default: false
    t.string "store_source"
    t.string "transaction_id"
    t.datetime "updated_at", null: false
    t.bigint "usd_price_cents"
    t.boolean "webhook_validated", default: false
    t.index ["date"], name: "index_purchase_events_on_date"
    t.index ["device_id", "project_id", "product_id", "event_type"], name: "idx_purchase_events_device_project_product_event"
    t.index ["device_id"], name: "index_purchase_events_on_device_id"
    t.index ["event_type"], name: "index_purchase_events_on_event_type"
    t.index ["id"], name: "index_purchase_events_on_unprocessed", where: "(processed = false)"
    t.index ["identifier"], name: "index_purchase_events_on_identifier"
    t.index ["link_id"], name: "index_purchase_events_on_link_id"
    t.index ["order_id", "project_id"], name: "idx_purchase_events_order_project"
    t.index ["project_id", "date", "event_type"], name: "index_purchase_events_on_project_date_event"
    t.index ["project_id", "original_transaction_id", "event_type"], name: "idx_purchase_events_project_orig_txn_type"
    t.index ["project_id", "product_id", "event_type", "device_id"], name: "idx_purchase_events_arppu"
    t.index ["project_id", "transaction_id", "event_type"], name: "idx_purchase_events_unique_txn", unique: true
    t.index ["project_id"], name: "index_purchase_events_on_project_id"
    t.index ["transaction_id"], name: "index_purchase_events_on_transaction_id"
  end

  create_table "quick_links", force: :cascade do |t|
    t.string "android_phone"
    t.string "android_tablet"
    t.datetime "created_at", null: false
    t.string "desktop"
    t.string "desktop_linux"
    t.string "desktop_mac"
    t.string "desktop_windows"
    t.bigint "domain_id", null: false
    t.string "image_url"
    t.string "ios_phone"
    t.string "ios_tablet"
    t.string "path", null: false
    t.string "subtitle"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["domain_id"], name: "index_quick_links_on_domain_id"
  end

  create_table "redirect_configs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "default_fallback"
    t.bigint "project_id"
    t.boolean "show_preview_android"
    t.boolean "show_preview_ios"
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_redirect_configs_on_project_id"
  end

  create_table "redirects", force: :cascade do |t|
    t.bigint "application_id"
    t.boolean "appstore"
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true
    t.string "fallback_url"
    t.string "platform"
    t.bigint "redirect_config_id"
    t.datetime "updated_at", null: false
    t.string "variation"
    t.index ["application_id"], name: "index_redirects_on_application_id"
    t.index ["redirect_config_id"], name: "index_redirects_on_redirect_config_id"
  end

  create_table "rpush_apps", force: :cascade do |t|
    t.string "access_token"
    t.datetime "access_token_expiration"
    t.text "apn_key"
    t.string "apn_key_id"
    t.string "auth_key"
    t.string "bundle_id"
    t.text "certificate"
    t.string "client_id"
    t.string "client_secret"
    t.integer "connections", default: 1, null: false
    t.datetime "created_at", null: false
    t.string "environment"
    t.boolean "feedback_enabled", default: true
    t.string "firebase_project_id"
    t.text "json_key"
    t.string "name", null: false
    t.string "password"
    t.string "team_id"
    t.string "type", null: false
    t.datetime "updated_at", null: false
  end

  create_table "rpush_feedback", force: :cascade do |t|
    t.integer "app_id"
    t.datetime "created_at", null: false
    t.string "device_token"
    t.datetime "failed_at", precision: nil, null: false
    t.datetime "updated_at", null: false
    t.index ["device_token"], name: "index_rpush_feedback_on_device_token"
  end

  create_table "rpush_notifications", force: :cascade do |t|
    t.text "alert"
    t.boolean "alert_is_json", default: false, null: false
    t.integer "app_id", null: false
    t.integer "badge"
    t.string "category"
    t.string "collapse_key"
    t.boolean "content_available", default: false, null: false
    t.datetime "created_at", null: false
    t.text "data"
    t.boolean "delay_while_idle", default: false, null: false
    t.datetime "deliver_after", precision: nil
    t.boolean "delivered", default: false, null: false
    t.datetime "delivered_at", precision: nil
    t.string "device_token"
    t.boolean "dry_run", default: false, null: false
    t.integer "error_code"
    t.text "error_description"
    t.integer "expiry", default: 86400
    t.string "external_device_id"
    t.datetime "fail_after", precision: nil
    t.boolean "failed", default: false, null: false
    t.datetime "failed_at", precision: nil
    t.boolean "mutable_content", default: false, null: false
    t.text "notification"
    t.integer "priority"
    t.boolean "processing", default: false, null: false
    t.text "registration_ids"
    t.integer "retries", default: 0
    t.string "sound"
    t.boolean "sound_is_json", default: false
    t.string "thread_id"
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.string "uri"
    t.text "url_args"
    t.index ["delivered", "failed", "processing", "deliver_after", "created_at"], name: "index_rpush_notifications_multi", where: "((NOT delivered) AND (NOT failed))"
  end

  create_table "setup_progress_steps", force: :cascade do |t|
    t.string "category", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.bigint "instance_id", null: false
    t.string "step_identifier", null: false
    t.datetime "updated_at", null: false
    t.index ["instance_id", "category", "step_identifier"], name: "idx_setup_progress_unique", unique: true
    t.index ["instance_id", "category"], name: "idx_setup_progress_instance_category"
  end

  create_table "store_images", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "identifier", null: false
    t.string "platform", null: false
    t.datetime "updated_at", null: false
    t.index ["identifier", "platform"], name: "index_store_images_on_identifier_and_platform", unique: true
  end

  create_table "stripe_payment_intents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "instance_id"
    t.string "intent_id"
    t.string "product_type"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["instance_id"], name: "index_stripe_payment_intents_on_instance_id"
    t.index ["user_id"], name: "index_stripe_payment_intents_on_user_id"
  end

  create_table "stripe_subscriptions", force: :cascade do |t|
    t.boolean "active"
    t.datetime "cancels_at"
    t.boolean "cancels_at_needs_backfill", default: false
    t.datetime "created_at", null: false
    t.string "customer_id"
    t.bigint "instance_id", null: false
    t.string "product_type"
    t.string "status"
    t.bigint "stripe_payment_intent_id"
    t.string "subscription_id"
    t.string "subscription_item_id"
    t.datetime "updated_at", null: false
    t.index ["instance_id"], name: "index_stripe_subscriptions_on_instance_id"
    t.index ["stripe_payment_intent_id"], name: "index_stripe_subscriptions_on_stripe_payment_intent_id"
  end

  create_table "stripe_webhook_messages", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "data"
    t.string "message_type"
    t.boolean "processed", default: true, null: false
    t.string "stripe_event_id"
    t.datetime "updated_at", null: false
    t.index ["stripe_event_id"], name: "index_stripe_webhook_messages_on_stripe_event_id", unique: true, where: "(stripe_event_id IS NOT NULL)"
  end

  create_table "subscription_states", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "device_id"
    t.string "latest_transaction_id"
    t.bigint "link_id"
    t.string "original_transaction_id", null: false
    t.string "product_id"
    t.bigint "project_id", null: false
    t.string "purchase_type"
    t.datetime "updated_at", null: false
    t.index ["device_id"], name: "index_subscription_states_on_device_id"
    t.index ["link_id"], name: "index_subscription_states_on_link_id"
    t.index ["project_id", "original_transaction_id"], name: "idx_subscription_states_project_orig_txn", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.integer "consumed_timestep"
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: ""
    t.datetime "invitation_accepted_at", precision: nil
    t.datetime "invitation_created_at", precision: nil
    t.integer "invitation_limit"
    t.datetime "invitation_sent_at", precision: nil
    t.string "invitation_token"
    t.integer "invitations_count", default: 0
    t.bigint "invited_by_id"
    t.string "invited_by_type"
    t.string "name"
    t.boolean "otp_required_for_login"
    t.string "otp_secret"
    t.string "provider"
    t.datetime "remember_created_at", precision: nil
    t.datetime "reset_password_sent_at", precision: nil
    t.string "reset_password_token"
    t.boolean "super_admin", default: false
    t.string "uid"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["invitation_token"], name: "index_users_on_invitation_token", unique: true
    t.index ["invited_by_id"], name: "index_users_on_invited_by_id"
    t.index ["invited_by_type", "invited_by_id"], name: "index_users_on_invited_by"
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "visitor_daily_statistics", force: :cascade do |t|
    t.integer "app_opens", default: 0, null: false
    t.datetime "created_at", null: false
    t.date "event_date", null: false
    t.integer "installs", default: 0, null: false
    t.bigint "invited_by_id"
    t.integer "opens", default: 0, null: false
    t.string "platform", default: "web", null: false
    t.bigint "project_id"
    t.integer "reactivations", default: 0, null: false
    t.integer "reinstalls", default: 0, null: false
    t.integer "revenue", default: 0, null: false
    t.bigint "time_spent", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_referred", default: 0, null: false
    t.integer "views", default: 0, null: false
    t.bigint "visitor_id", null: false
    t.index ["event_date", "project_id", "platform"], name: "idx_vds_date_project_platform"
    t.index ["event_date", "project_id"], name: "idx_vds_date_project"
    t.index ["project_id", "event_date", "visitor_id"], name: "idx_vds_project_date_visitor"
    t.index ["project_id", "visitor_id", "event_date", "platform"], name: "uniq_vds_proj_visitor_date_platform", unique: true
    t.index ["visitor_id"], name: "idx_vds_visitor_id"
  end

  create_table "visitor_last_visits", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "link_id"
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "visitor_id", null: false
    t.index ["link_id"], name: "index_visitor_last_visits_on_link_id"
    t.index ["project_id", "visitor_id"], name: "index_vlv_on_project_and_visitor", unique: true
    t.index ["project_id"], name: "index_visitor_last_visits_on_project_id"
    t.index ["visitor_id"], name: "index_visitor_last_visits_on_visitor_id"
  end

  create_table "visitors", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "device_id", null: false
    t.integer "inviter_id"
    t.bigint "project_id", null: false
    t.jsonb "sdk_attributes"
    t.string "sdk_identifier"
    t.datetime "updated_at", null: false
    t.uuid "uuid", default: -> { "gen_random_uuid()" }
    t.boolean "web_visitor", default: false
    t.index ["device_id"], name: "index_visitors_on_device_id"
    t.index ["inviter_id"], name: "index_visitors_on_inviter_id"
    t.index ["project_id", "created_at"], name: "idx_visitors_project_created_desc", order: { created_at: :desc }
    t.index ["project_id"], name: "index_visitors_on_project_id"
    t.index ["uuid"], name: "index_visitors_on_uuid", unique: true
    t.index ["web_visitor"], name: "index_visitors_on_web_visitor"
  end

  create_table "web_configuration_linked_domains", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "domain"
    t.datetime "updated_at", null: false
    t.bigint "web_configuration_id"
    t.index ["web_configuration_id"], name: "index_web_configuration_linked_domains_on_web_configuration_id"
  end

  create_table "web_configurations", force: :cascade do |t|
    t.bigint "application_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["application_id"], name: "index_web_configurations_on_application_id", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "android_push_configurations", "android_configurations"
  add_foreign_key "android_server_api_keys", "android_configurations"
  add_foreign_key "applications", "instances"
  add_foreign_key "campaigns", "projects"
  add_foreign_key "custom_redirects", "links"
  add_foreign_key "domains", "projects"
  add_foreign_key "iap_webhook_messages", "projects"
  add_foreign_key "installed_apps", "devices"
  add_foreign_key "installed_apps", "projects"
  add_foreign_key "instance_roles", "instances"
  add_foreign_key "instance_roles", "users"
  add_foreign_key "ios_configurations", "applications"
  add_foreign_key "ios_push_configurations", "ios_configurations"
  add_foreign_key "ios_server_api_keys", "ios_configurations"
  add_foreign_key "links", "campaigns"
  add_foreign_key "links", "domains"
  add_foreign_key "links", "visitors"
  add_foreign_key "mcp_authorization_codes", "users"
  add_foreign_key "mcp_tokens", "users"
  add_foreign_key "notification_messages", "notifications"
  add_foreign_key "notification_messages", "visitors"
  add_foreign_key "notification_targets", "notifications"
  add_foreign_key "notifications", "projects"
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id"
  add_foreign_key "projects", "instances"
  add_foreign_key "purchase_events", "devices"
  add_foreign_key "purchase_events", "links"
  add_foreign_key "purchase_events", "projects"
  add_foreign_key "redirect_configs", "projects"
  add_foreign_key "redirects", "applications"
  add_foreign_key "redirects", "redirect_configs"
  add_foreign_key "setup_progress_steps", "instances"
  add_foreign_key "stripe_subscriptions", "instances"
  add_foreign_key "stripe_subscriptions", "stripe_payment_intents"
  add_foreign_key "subscription_states", "projects", on_delete: :cascade
  add_foreign_key "visitor_last_visits", "links"
  add_foreign_key "visitor_last_visits", "projects"
  add_foreign_key "visitor_last_visits", "visitors"
  add_foreign_key "visitors", "devices"
  add_foreign_key "visitors", "projects"
end
