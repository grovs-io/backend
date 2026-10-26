Rails.application.routes.draw do
  # Kamal health check
  get '/up', to: proc { [200, {}, ['OK']] }
  get '/favicon.ico', to: ->(_) { [204, {}, []] }

  constraints(PreviewSubdomain) do
    get '/*value', to: "public/links#make_redirect"
    get '/', to: "public/links#make_redirect"
  end

  constraints(PublicSubdomain) do
    get '.well-known/apple-app-site-association', to: "public/verification#generate_ios_file"
    get '.well-known/assetlinks.json',to: "public/verification#generate_android_file"
    get '.well-known/grovs-domain-verification', to: "public/verification#domain_verification"

    get '/*value', to: "public/links#open_app_link"
    get '/', to: "public/links#open_app_link"
    post '/', to: "public/device_data#store_device_data"
  end

  constraints(McpSubdomain) do
    # OAuth 2.1 discovery endpoints
    get '.well-known/oauth-protected-resource', to: "mcp/oauth_metadata#protected_resource"
    get '.well-known/oauth-authorization-server', to: "mcp/oauth_metadata#authorization_server"

    # OAuth 2.1 flow endpoints
    post '/register', to: "mcp/registration#create"
    get '/authorize', to: "mcp/authorize#show"
    post '/token', to: "mcp/token#create"

    # MCP API endpoints (protected by MCP token)
    namespace :api, defaults: { format: :json } do
      namespace :v1 do
        get 'mcp/status', to: "mcp/auth#status"
        get 'mcp/usage', to: "mcp/auth#usage"
        get 'mcp/validate', to: "mcp/auth#validate"
        delete 'mcp/token', to: "mcp/auth#revoke_token"
        get 'mcp/tokens', to: "mcp/auth#list_tokens"
        post 'mcp/projects', to: "mcp/projects#create"
        put 'mcp/redirects', to: "mcp/configurations#setup_redirects"
        put 'mcp/sdk', to: "mcp/configurations#setup_sdk"
        post 'mcp/links/search', to: "mcp/links#index"
        post 'mcp/links', to: "mcp/links#create"
        get 'mcp/links/by-path/:path', to: "mcp/links#show"
        patch 'mcp/links/:id', to: "mcp/links#update"
        delete 'mcp/links/:id', to: "mcp/links#archive"
        post 'mcp/analytics/link', to: "mcp/analytics#link_stats"
        post 'mcp/analytics/overview', to: "mcp/analytics#project_metrics"
        post 'mcp/analytics/top_links', to: "mcp/analytics#top_links"
        # Campaigns
        post 'mcp/campaigns', to: "mcp/campaigns#create"
        post 'mcp/campaigns/search', to: "mcp/campaigns#index"
        delete 'mcp/campaigns/:campaign_id', to: "mcp/campaigns#archive"

        # Dashboard controllers reused through McpProjectController; POST so the client sends JSON bodies.
        scope 'mcp/projects/:id', module: :mcp, as: :mcp_project do
          post 'analytics/query', to: 'analytics/query#show'
          post 'analytics/key-metrics', to: 'analytics/overview#key_metrics'
          post 'analytics/retention', to: 'analytics/retention#summary'
          post 'analytics/events', to: 'analytics/events_explorer#index'
          post 'analytics/events/fields', to: 'analytics/events_explorer#fields'
          post 'analytics/events/field-values', to: 'analytics/events_explorer#field_values'
          post 'dashboards/list', to: 'dashboards#index'
          post 'dashboards', to: 'dashboards#create'

          if Grovs.ee?
            post 'segments/list', to: 'segments#index'
            post 'segments/fields', to: 'segments#fields'
            post 'segments/estimate', to: 'segments#estimate'
            post 'segments', to: 'segments#create'
            post 'segments/:segment_id/breakdown', to: 'segments#breakdown'
            post 'push_campaigns/list', to: 'push_campaigns#index'
            post 'push_campaigns/:campaign_id', to: 'push_campaigns#show'
            post 'push_campaigns/:campaign_id/experiment', to: 'push_campaigns#experiment'
            post 'in_app_campaigns/list', to: 'in_app_campaigns#index'
            post 'in_app_campaigns/:campaign_id', to: 'in_app_campaigns#show'
            post 'in_app_campaigns/:campaign_id/report', to: 'in_app_campaigns#report'
            post 'in_app_campaigns/:campaign_id/experiment', to: 'in_app_campaigns#experiment'
            post 'in_app_campaigns/:campaign_id/comments', to: 'in_app_campaigns#comments'
            post 'journeys/list', to: 'journeys#index'
            post 'journeys/:journey_id/report', to: 'journeys#report'
          end
        end
      end
    end
  end

  constraints(ApiSubdomain) do
    # The dashboard builds this from config.apiUrl's bare origin, not under /api/v1.
    get '/in_app/preview', to: "public/in_app_preview#show" if Grovs.ee?

    namespace :api, defaults: {format: :json} do
      namespace :v1 do

        # Users
        scope :users, controller: :users do
          post '/', action: :create
          post 'reset_password'
          post 'change_password'
          post 'accept_invite'
          get 'me', action: :current_user_details
          patch 'me', action: :edit_user
          delete 'me', action: :remove_user
          post 'otp_status', action: :otp_enabled
          get 'me/otp_qr', action: :otp_qr
          put 'me/two_factor', action: :set_2fa_enabled
        end

        # Configurations
        get 'instances/:id/configurations', to: "configurations#current_project_configurations"
        put 'instances/:id/configurations/ios', to: "configurations#set_ios_configuration"
        put 'instances/:id/configurations/android', to: "configurations#set_android_configuration"
        put 'instances/:id/configurations/desktop', to: "configurations#set_desktop_configuration"
        put 'instances/:id/configurations/web', to: "configurations#set_web_configuration"
        put 'instances/:id/configurations/ios/push', to: "configurations#set_ios_push_configuration"
        put 'instances/:id/configurations/android/push', to: "configurations#set_android_push_configuration"
        put 'instances/:id/configurations/android/api_access_key', to: "configurations#set_android_api_access_key"
        put 'instances/:id/configurations/ios/api_access_key', to: "configurations#set_ios_api_access_key"
        delete 'instances/:id/configurations/ios', to: "configurations#remove_ios_configuration"
        delete 'instances/:id/configurations/android', to: "configurations#remove_android_configuration"
        delete 'instances/:id/configurations/desktop', to: "configurations#remove_desktop_configuration"
        delete 'instances/:id/configurations/web', to: "configurations#remove_web_configuration"
        get 'instances/:id/configurations/android/google_configuration_script', to: "configurations#google_configuration_script"

        # Redirect configurations
        get 'projects/:id/redirect_config', to: "redirects#redirect_config"
        put 'projects/:id/redirect_config', to: "redirects#set_redirect_config"
        put 'projects/:id/redirect_config/redirect', to: "redirects#set_redirect"

        # Smart banners
        patch  'projects/:id/smart_banners/reorder', to: "smart_banners#reorder"
        get    'projects/:id/smart_banners/status', to: "smart_banners#status"
        get    'projects/:id/smart_banners', to: "smart_banners#index"
        post   'projects/:id/smart_banners', to: "smart_banners#create"
        post   'projects/:id/smart_banners/:banner_id/duplicate', to: "smart_banners#duplicate"
        get    'projects/:id/smart_banners/:banner_id', to: "smart_banners#show"
        patch  'projects/:id/smart_banners/:banner_id', to: "smart_banners#update"
        delete 'projects/:id/smart_banners/:banner_id', to: "smart_banners#destroy"

        # Domains
        get 'projects/:id/domain', to: "domains#current_project_domain"
        get 'projects/:id/domain/defaults', to: "domains#domain_defaults"
        put 'projects/:id/domain', to: "domains#set_project_domain"
        post 'projects/:id/domain/check_availability', to: "domains#domain_is_available"
        put 'projects/:id/domain/google_tracking_id', to: "domains#set_google_tracking_id"

        get    'projects/:id/custom_domain', to: "domains#custom_domain"
        post   'projects/:id/custom_domain', to: "domains#create_custom_domain"
        delete 'projects/:id/custom_domain', to: "domains#delete_custom_domain"

        # `purpose` passes via body (POST) or query string (DELETE), not path.
        get    'projects/:id/custom_domains', to: "domains#index_custom_domains"
        post   'projects/:id/custom_domains', to: "domains#create_custom_domain_v2"
        delete 'projects/:id/custom_domains', to: "domains#delete_custom_domain_v2"

        # Pure DNS lookup; does NOT require the hostname to be a registered CustomHostname.
        get    'projects/:id/custom_domains/preflight', to: "domains#preflight_custom_domain"
        post   'projects/:id/custom_domains/verify', to: "domains#verify_custom_domain"

        # Event stream (Enterprise)
        if Grovs.ee?
          get    'projects/:id/event_destinations', to: "event_destinations#index"
          post   'projects/:id/event_destinations', to: "event_destinations#create"
          patch  'projects/:id/event_destinations/:destination_id', to: "event_destinations#update"
          delete 'projects/:id/event_destinations/:destination_id', to: "event_destinations#destroy"
          post   'projects/:id/event_destinations/:destination_id/pause', to: "event_destinations#pause"
          post   'projects/:id/event_destinations/:destination_id/resume', to: "event_destinations#resume"
          post   'projects/:id/event_destinations/:destination_id/rewind', to: "event_destinations#rewind"
          post   'projects/:id/event_destinations/:destination_id/test', to: "event_destinations#test"
          post   'projects/:id/event_exports', to: "event_destinations#create_export"

          get    'projects/:id/segments', to: "segments#index"
          post   'projects/:id/segments', to: "segments#create"
          get    'projects/:id/segments/fields', to: "segments#fields"
          post   'projects/:id/segments/estimate', to: "segments#estimate"
          post   'projects/:id/segments/:segment_id/count', to: "segments#count"
          post   'projects/:id/segments/:segment_id/identifier_list', to: "segments#identifier_list"
          get    'projects/:id/segments/:segment_id/identifier_list', to: "segments#identifier_list_preview"
          get    'projects/:id/segments/:segment_id/identifier_list/download', to: "segments#identifier_list_download"
          post   'projects/:id/segments/:segment_id/breakdown', to: "segments#breakdown"
          post   'projects/:id/segments/:segment_id/users', to: "segments#users"
          post   'projects/:id/segments/:segment_id/export', to: "segments#export"
          get    'projects/:id/segment_exports', to: "segments#exports"
          get    'projects/:id/segment_exports/:export_id', to: "segments#export_status"
          get    'projects/:id/segments/:segment_id/size_history', to: "segments#size_history"
          get    'projects/:id/segments/:segment_id', to: "segments#show"
          patch  'projects/:id/segments/:segment_id', to: "segments#update"
          delete 'projects/:id/segments/:segment_id', to: "segments#destroy"
          get    'projects/:id/push_campaigns', to: "push_campaigns#index"
          post   'projects/:id/push_campaigns', to: "push_campaigns#create"
          post   'projects/:id/push_campaigns/estimate', to: "push_campaigns#estimate_audience"
          get    'projects/:id/push_campaigns/:campaign_id', to: "push_campaigns#show"
          patch  'projects/:id/push_campaigns/:campaign_id', to: "push_campaigns#update"
          post   'projects/:id/push_campaigns/:campaign_id/send', to: "push_campaigns#send_now"
          post   'projects/:id/push_campaigns/:campaign_id/cancel', to: "push_campaigns#cancel"
          post   'projects/:id/push_campaigns/:campaign_id/send_winner', to: "push_campaigns#send_winner"
          get    'projects/:id/push_campaigns/:campaign_id/experiment', to: "push_campaigns#experiment"
          post   'projects/:id/push_campaigns/:campaign_id/estimate', to: "push_campaigns#estimate"
          get    'projects/:id/push_campaigns/:campaign_id/deliveries', to: "push_campaigns#deliveries"
          delete 'projects/:id/push_campaigns/:campaign_id/image', to: "push_campaigns#remove_image"

          get    'projects/:id/in_app_settings', to: "in_app_settings#show"
          patch  'projects/:id/in_app_settings', to: "in_app_settings#update"
          get    'projects/:id/in_app_campaigns', to: "in_app_campaigns#index"
          post   'projects/:id/in_app_campaigns', to: "in_app_campaigns#create"
          get    'projects/:id/in_app_campaigns/:campaign_id', to: "in_app_campaigns#show"
          patch  'projects/:id/in_app_campaigns/:campaign_id', to: "in_app_campaigns#update"
          delete 'projects/:id/in_app_campaigns/:campaign_id', to: "in_app_campaigns#destroy"
          post   'projects/:id/in_app_campaigns/:campaign_id/launch', to: "in_app_campaigns#launch"
          post   'projects/:id/in_app_campaigns/:campaign_id/pause', to: "in_app_campaigns#pause"
          post   'projects/:id/in_app_campaigns/:campaign_id/resume', to: "in_app_campaigns#resume"
          post   'projects/:id/in_app_campaigns/:campaign_id/end', to: "in_app_campaigns#finish"
          post   'projects/:id/in_app_campaigns/:campaign_id/duplicate', to: "in_app_campaigns#duplicate"
          post   'projects/:id/in_app_campaigns/:campaign_id/update_audience', to: "in_app_campaigns#update_audience"
          post   'projects/:id/in_app_campaigns/:campaign_id/test', to: "in_app_campaigns#test"
          get    'projects/:id/in_app_campaigns/:campaign_id/report', to: "in_app_campaigns#report"
          get    'projects/:id/in_app_campaigns/:campaign_id/answers', to: "in_app_campaigns#answers"
          get    'projects/:id/in_app_campaigns/:campaign_id/comments', to: "in_app_campaigns#comments"
          get    'projects/:id/in_app_campaigns/:campaign_id/experiment', to: "in_app_campaigns#experiment"
          post   'projects/:id/in_app_campaigns/:campaign_id/images/:slot', to: "in_app_campaigns#upload_image"
          delete 'projects/:id/in_app_campaigns/:campaign_id/images/:slot', to: "in_app_campaigns#remove_image"
          get    'projects/:id/in_app_campaigns/:campaign_id/media', to: "in_app_campaigns#media_index"
          post   'projects/:id/in_app_campaigns/:campaign_id/media', to: "in_app_campaigns#upload_media"
          delete 'projects/:id/in_app_campaigns/:campaign_id/media/:media_id', to: "in_app_campaigns#remove_media"
          get    'projects/:id/journeys', to: "journeys#index"
          post   'projects/:id/journeys', to: "journeys#create"
          get    'projects/:id/journeys/:journey_id', to: "journeys#show"
          patch  'projects/:id/journeys/:journey_id', to: "journeys#update"
          delete 'projects/:id/journeys/:journey_id', to: "journeys#destroy"
          post   'projects/:id/journeys/:journey_id/launch', to: "journeys#launch"
          post   'projects/:id/journeys/:journey_id/pause', to: "journeys#pause"
          post   'projects/:id/journeys/:journey_id/resume', to: "journeys#resume"
          post   'projects/:id/journeys/:journey_id/end', to: "journeys#finish"
          post   'projects/:id/journeys/:journey_id/duplicate', to: "journeys#duplicate"
          get    'projects/:id/journeys/:journey_id/report', to: "journeys#report"
          post   'projects/:id/journeys/:journey_id/images', to: "journeys#upload_image"

          get    'projects/:id/event_stream', to: "event_stream#index"
          get    'projects/:id/event_stream_tokens', to: "event_stream#tokens"
          post   'projects/:id/event_stream_tokens', to: "event_stream#create_token"
          delete 'projects/:id/event_stream_tokens/:token_id', to: "event_stream#destroy_token"
        end

        # Combined CH + MigrationSource creation (atomic). Standalone create on
        # /migration_source was removed because every legitimate flow needs both rows.
        post   'projects/:id/migrations', to: "migrations#create"

        get    'projects/:id/migration_source',      to: "migration_sources#show"
        patch  'projects/:id/migration_source',      to: "migration_sources#update"
        delete 'projects/:id/migration_source',      to: "migration_sources#destroy"
        post   'projects/:id/migration_source/test', to: "migration_sources#test"

        # Links
        post 'projects/:id/links', to: "links#create_link"
        # DEPRECATED / MARKED FOR DELETION (2026-07-15): superseded by links/search_v2.
        # FE calls only search_v2; verify zero server traffic before removing this route + action.
        post 'projects/:id/links/search', to: "links#current_project_links"
        post 'projects/:id/links/search_v2', to: "links#current_project_links_v2"
        post 'projects/:id/links/by_ids', to: "links#links_by_ids"
        post 'projects/:id/links/check_path', to: "links#is_path_available"
        get 'projects/:id/links/lookup', to: "links#lookup"
        patch 'projects/:id/links/:link_id', to: "links#update_link"
        delete 'projects/:id/links/:link_id', to: "links#remove_link"
        get 'projects/:id/links/:link_id/last_open', to: "links#last_open"
        get 'projects/:id/links/random_path', to: "links#generate_path"

        # Campaigns
        post 'projects/:id/campaigns', to: "campaigns#create"
        patch 'projects/:id/campaigns/:campaign_id', to: "campaigns#update"
        delete 'projects/:id/campaigns/:campaign_id', to: "campaigns#archive"
        # DEPRECATED / MARKED FOR DELETION (2026-07-15): superseded by campaigns/search_v2.
        # Backed by EventMetricsQuery#sorted_by_campaigns (2x raw-events scans + COUNT(DISTINCT device_id)).
        # FE calls only search_v2; verify zero server traffic before removing this route + action.
        post 'projects/:id/campaigns/search', to: "campaigns#current_project_campaigns"
        post 'projects/:id/campaigns/search_v2', to: "campaigns#current_project_campaigns_v2"
        # DEPRECATED (2026-07-25): unused by grovs-web-app — remove after zero-traffic check
        post 'projects/:id/campaigns/metrics_overview', to: "campaigns#metrics_for_overview"

        # Dashboards (custom widget boards)
        get 'projects/:id/dashboards', to: "dashboards#index"
        post 'projects/:id/dashboards', to: "dashboards#create"
        patch 'projects/:id/dashboards/:dashboard_id', to: "dashboards#update"
        delete 'projects/:id/dashboards/:dashboard_id', to: "dashboards#destroy"
        post 'projects/:id/dashboards/:dashboard_id/widgets', to: "dashboards#create_widget"
        patch 'projects/:id/dashboards/:dashboard_id/widgets/:widget_id', to: "dashboards#update_widget"
        delete 'projects/:id/dashboards/:dashboard_id/widgets/:widget_id', to: "dashboards#destroy_widget"
        get 'projects/:id/sdk_status', to: "sdk_status#show"

        # Events
        post 'projects/:id/events/search', to: "events#events_for_search_params"
        post 'projects/:id/events/sorted', to: "events#events_sorted_by_param"
        get 'projects/:id/events/metric_values', to: "events#metrics_values"
        post 'projects/:id/events/overview', to: "events#events_for_overview"
        post 'instances/:id/events/billing', to: "events#events_for_payment_screen"

        # Exports
        post 'projects/:id/exports/links', to: "export#export_link_data"
        # DEPRECATED (2026-07-25): unused by grovs-web-app — remove after zero-traffic check
        post 'instances/:id/exports/usage', to: "export#export_usage_data"

        # Visitors
        post 'projects/:id/visitors/aggregated', to: "visitors#aggregated_visitors"
        post 'projects/:id/visitors/search', to: "visitors#visitors"
        get 'projects/:id/visitors/:visitor_id', to: "visitors#visitor_details"
        # DEPRECATED / MARKED FOR DELETION (2026-07-15): legacy per-visitor event CASE-sum
        # aggregation over the RAW events table with NO date bound — catastrophic at scale.
        # FE no longer calls these paths (only a response-type field shares the name).
        # Verify zero server traffic, then remove these routes + the two controller actions.
        post 'projects/:id/visitors/aggregated_metrics', to: "visitors#aggregated_visitor_metrics_for_search_params"
        post 'projects/:id/visitors/metrics', to: "visitors#visitor_metrics_for_search_params"

        # Purchases (Enterprise)
        if Grovs.ee?
          post 'projects/:id/purchases/search', to: "purchases#purchases"
          post 'projects/:id/purchases/revenue', to: "purchases#revenue_metrics"
        end

        # Dashboard
        # DEPRECATED (2026-07-25): route only — DashboardMetrics stays (MCP consumer)
        post 'projects/:id/dashboard/metrics_overview', to: "dashboard#metrics_overview"
        # DEPRECATED (2026-07-25): unused by grovs-web-app — remove after zero-traffic check
        post 'projects/:id/dashboard/links_views', to: "dashboard#links_views"
        post 'projects/:id/dashboard/top_links', to: "dashboard#best_performing_links"

        # Analytics (ClickHouse-backed)
        scope 'projects/:id/analytics' do
          # Events Explorer
          get 'events', to: 'analytics/events_explorer#index'
          get 'events/volume', to: 'analytics/events_explorer#volume'
          get 'events/field-values', to: 'analytics/events_explorer#field_values'
          get 'events/fields', to: 'analytics/events_explorer#fields'
          get 'events/:event_id', to: 'analytics/events_explorer#show'

          # Overview (metrics + version dimension)
          get 'overview/key-metrics', to: 'analytics/overview#key_metrics'
          get 'overview/key-metrics/series', to: 'analytics/overview#key_metric_series'
          # DEPRECATED (2026-07-25): superseded by version_distribution — remove after zero-traffic check
          get 'overview/versions', to: 'analytics/overview#versions'
          get 'overview/versions/distribution', to: 'analytics/overview#version_distribution'
          get 'overview/trends/users', to: 'analytics/overview#user_trends'
          # DEPRECATED (2026-07-25): unused by grovs-web-app — remove after zero-traffic check
          get 'overview/sources/breakdown', to: 'analytics/overview#sources_breakdown'

          # Retention summary (D1/D7/D30)
          get 'retention/summary', to: 'analytics/retention#summary'

          # Sessions (Explore-only: list + detail). :session_key is an opaque
          # encoded (session_id + visitor_id) key from list rows — URL-safe,
          # slash-free. Named :session_key (not :id) to avoid colliding with the
          # scope's project :id param.
          get 'sessions', to: 'analytics/sessions#index'
          get 'sessions/:session_key', to: 'analytics/sessions#show'

          # Generic metric query (breakdowns, series, widgets)
          get 'query', to: 'analytics/query#show'
        end


        # Instances
        post 'instances', to: "instances#create_instance"
        get 'instances', to: "instances#current_user_instances"
        get 'instances/:id', to: "instances#instance_details"
        put 'instances/:id', to: "instances#edit_instance"
        delete 'instances/:id', to: "instances#delete_instance"
        get 'instances/:id/members', to: "instances#members_for_instance"
        post 'instances/:id/members', to: "instances#add_member_to_instance"
        delete 'instances/:id/members', to: "instances#remove_member_from_instance"
        get 'instances/:id/role', to: "instances#user_role_for_instance"
        put 'instances/:id/revenue_collection', to: "instances#set_revenue_collection_enabled"
        post 'instances/:id/dismiss_get_started', to: "instances#dismiss_get_started"
        get 'instances/:id/setup_progress', to: "instances#setup_progress"
        post 'instances/:id/setup_progress/complete', to: "instances#complete_setup_step"

        # Audit log (Enterprise)
        if Grovs.ee?
          get 'instances/:id/audit_events', to: "audit_events#index"
          get 'instances/:id/audit_events/head', to: "audit_events#latest"
          get 'instances/:id/audit_export_tokens', to: "audit_export_tokens#index"
          post 'instances/:id/audit_export_tokens', to: "audit_export_tokens#create"
          delete 'instances/:id/audit_export_tokens/:token_id', to: "audit_export_tokens#destroy"
          get 'instances/:id/sso_connection', to: "sso_connections#show"
          put 'instances/:id/sso_connection', to: "sso_connections#upsert"
          delete 'instances/:id/sso_connection', to: "sso_connections#destroy"
          post 'instances/:id/sso_connection/verify_domains', to: "sso_connections#verify_domains"
          post 'instances/:id/sso_connection/scim_token', to: "sso_connections#create_scim_token"
          delete 'instances/:id/sso_connection/scim_token', to: "sso_connections#destroy_scim_token"
        end

        # Billing
        post 'instances/:id/billing/subscriptions', to: "payments#create_subscription_session"
        get 'instances/:id/billing/stripe_portal', to: "payments#stripe_dashboard_url"
        delete 'instances/:id/billing/subscription', to: "payments#cancel_subscription"
        post 'instances/:id/billing/subscription/resume', to: "payments#resume_subscription"
        get 'instances/:id/billing/subscription', to: "payments#subscription_details"
        get 'instances/:id/billing/mau', to: "payments#current_mau"
        get 'instances/:id/billing/usage', to: "payments#current_usage"

        # Automation (machine-to-machine, unchanged)
        post 'automation/metrics_for_user', to: "automation#metrics_for_user"
        post 'automation/details_for_link', to: "automation#details_for_link"

        # MCP (Model Context Protocol) — dashboard-only routes (Doorkeeper-protected)
        post 'mcp/approve_consent', to: "mcp/auth#approve_consent"
        get 'mcp/tokens', to: "mcp/auth#list_tokens"
        delete 'mcp/tokens/:id', to: "mcp/auth#revoke_token_by_id"

        # Admin (machine-to-machine, unchanged)
        post 'admin/create_enterprise_subscription', to: "admin#create_enterprise_subscription"
        patch 'admin/update_enterprise_subscription', to: "admin#update_enterprise_subscription"
        post 'admin/create_custom_domain', to: "admin#create_custom_domain"
        post 'admin/migrate_firebase_links', to: "admin#migrate_firebase_links"
        post 'admin/flush_events', to: "admin#flush_events"
        patch 'admin/instance_retention', to: "admin#update_instance_retention"

        # Diagnostics (unchanged)
        get 'diagnostics/test_exception', to: "diagnostics#test_exception"
        post 'diagnostics/test_exception', to: "diagnostics#test_exception"
        get 'diagnostics/test_logs', to: "diagnostics#test_logs"
        post 'diagnostics/test_logs', to: "diagnostics#test_logs"
        get 'diagnostics/test_diagnostics', to: "diagnostics#test_diagnostics"
        post 'diagnostics/test_diagnostics', to: "diagnostics#test_diagnostics"
        get 'diagnostics/health_metrics', to: "diagnostics#health_metrics"

        # Webhooks (unchanged)
        post 'webhooks/stripe', to: "webhooks#stripe_webhook"
        post 'webhooks/send_stripe_quotas'

        # IAP (Enterprise)
        if Grovs.ee?
          post 'iap/apple/production/:path', to: 'iap#apple_prod'
          post 'iap/apple/test/:path', to: 'iap#apple_test'
          post 'iap/google/:path', to: 'iap#google_handling'
        end

      end
    end

    if Grovs.ee?
      namespace :scim_v2, path: "scim/v2" do
        get 'Users', to: 'users#index'
        get 'Users/:id', to: 'users#show'
        post 'Users', to: 'users#create'
        put 'Users/:id', to: 'users#replace'
        patch 'Users/:id', to: 'users#update'
        delete 'Users/:id', to: 'users#destroy'
        mount Scimitar::Engine, at: "/"
      end
    end
  end

  constraints(GoSubdomain) do
    post '/create', to: "public/public_link#create"
    get '/*path', to: "public/public_link#get_link"
  end

  constraints(SdkSubdomain) do
    # SDK
    namespace :api, defaults: {format: :json} do
      namespace :v1 do
        # Auth (no device auth required)
        post 'sdk/authenticate', to: "sdk/auth#authenticate"
        get 'sdk/device_for_vendor_id', to: "sdk/auth#device_for_vendor"

        # Links
        post 'sdk/data_for_device', to: "sdk/links#data_for_device_details"
        post 'sdk/data_for_device_and_url', to: "sdk/links#data_for_device_details_and_url"
        post 'sdk/data_for_device_and_path', to: "sdk/links#data_for_device_details_and_path"
        post 'sdk/link_details', to: "sdk/links#link_details"
        post 'sdk/clipboard_status', to: "sdk/links#clipboard_status"
        post 'sdk/create_link', to: "sdk/links#create_link"

        # Smart banners
        get 'sdk/smart_banners', to: "sdk/smart_banners#index"
        post 'sdk/smart_banners/:banner_id/link', to: "sdk/smart_banners#link"

        # Events
        post 'sdk/event', to: "sdk/events#add_event"
        post 'sdk/event/custom', to: "sdk/events#add_custom_event"
        post 'sdk/events/batch', to: "sdk/events#add_batch"

        # The removed messages inbox: kept, and answering empty, for the apps already released
        post 'sdk/notifications_for_device', to: "sdk/notifications#notifications_for_device"
        post 'sdk/push_open', to: "sdk/push#open"
        get 'sdk/number_of_unread_notifications', to: "sdk/notifications#number_of_unread_notifications"
        post 'sdk/mark_notification_as_read', to: "sdk/notifications#mark_notification_as_read"
        get 'sdk/notifications_to_display_automatically', to: "sdk/notifications#notifications_to_display_automatically"

        # Screen Aliases
        post 'sdk/screen_aliases', to: "sdk/screen_aliases#create"

        # Visitors
        get 'sdk/visitor_attributes', to: "sdk/visitors#visitor_attributes"
        post 'sdk/visitor_attributes', to: "sdk/visitors#set_visitor_attributes"

        # Payments (Enterprise)
        if Grovs.ee?
          post 'sdk/add_payment_event', to: "sdk/payments#add_payment_event"
          post 'sdk/in_app/sync', to: "sdk/in_app#sync"
        end

        # SERVER
        post 'sdk/generate_link', to: "server_sdk#generate_link"
        get 'sdk/link/:path', to: "server_sdk#link_details"
        get 'sdk/metrics_for_link/:path', to: 'server_sdk#metrics_for_link'
        get 'sdk/metrics_for_project', to: 'server_sdk#metrics_for_project'
        post 'sdk/server/push', to: 'server_sdk#push'
        get 'sdk/server/push/:campaign_id', to: 'server_sdk#push_status'

        # Dashboard controllers behind the instance API key; only these actions are reachable.
        if Grovs.ee?
          scope 'sdk/server', module: :server, as: :server_api do
            get    'segments', to: 'segments#index'
            post   'segments', to: 'segments#create'
            get    'segments/fields', to: 'segments#fields'
            post   'segments/estimate', to: 'segments#estimate'
            get    'segments/:segment_id', to: 'segments#show'
            patch  'segments/:segment_id', to: 'segments#update'
            delete 'segments/:segment_id', to: 'segments#destroy'
            post   'segments/:segment_id/count', to: 'segments#count'
            post   'segments/:segment_id/identifier_list', to: 'segments#identifier_list'
            get    'in_app_campaigns', to: 'in_app_campaigns#index'
            post   'in_app_campaigns', to: 'in_app_campaigns#create'
            get    'in_app_campaigns/:campaign_id', to: 'in_app_campaigns#show'
            patch  'in_app_campaigns/:campaign_id', to: 'in_app_campaigns#update'
            delete 'in_app_campaigns/:campaign_id', to: 'in_app_campaigns#destroy'
            post   'in_app_campaigns/:campaign_id/launch', to: 'in_app_campaigns#launch'
            post   'in_app_campaigns/:campaign_id/pause', to: 'in_app_campaigns#pause'
            post   'in_app_campaigns/:campaign_id/resume', to: 'in_app_campaigns#resume'
            post   'in_app_campaigns/:campaign_id/end', to: 'in_app_campaigns#finish'
            post   'in_app_campaigns/:campaign_id/test', to: 'in_app_campaigns#test'
            get    'in_app_campaigns/:campaign_id/report', to: 'in_app_campaigns#report'
          end
        end

      end
    end
  end

  # Legacy IAP webhook routes — kept for backward compatibility with Apple/Google webhook configurations
  namespace :api do
    namespace :v1 do
      if Grovs.ee?
        # apple
        post 'iap/apple/production/:path', to: 'iap#apple_prod'
        # apple sandbox
        post 'iap/apple/test/:path', to: 'iap#apple_test'
        # google
        post 'iap/google/:path', to: 'iap#google_handling'
      end


      namespace :identity do
        namespace :sso do
          # Which SSO providers this deployment has credentials for (self-hosted).
          get '/providers', to: 'sessions#providers'

          # OmniAuth callback route
          post '/discover', to: 'sessions#discover'
          post '/auth/:provider', to: 'sessions#passthru', as: :auth_request
          get '/auth/:provider/callback', to: 'sessions#create'
          post '/auth/:provider/callback', to: 'sessions#create'
          get '/auth/failure', to: 'sessions#omniauth_failure'

          # Refresh token
          post '/tokens/refresh', to: 'tokens#refresh_token'
        end
      end

    end
  end

  namespace :public do
    get '/', to: "links#open_app_link"
  end

  devise_for :users, skip: [:registrations]
  use_doorkeeper do
    controllers tokens: 'custom_tokens'
    skip_controllers :authorizations, :applications, :authorized_applications
  end
end
