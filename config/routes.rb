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

    get '/mm/*value', to: "public/marketing_messages#open_marketing_message"
    get '/*value', to: "public/links#open_app_link"
    get '/', to: "public/links#open_app_link"
    post '/', to: "public/device_data#store_device_data"
  end

  constraints(ApiSubdomain) do
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

        # Domains
        get 'projects/:id/domain', to: "domains#current_project_domain"
        get 'projects/:id/domain/defaults', to: "domains#domain_defaults"
        put 'projects/:id/domain', to: "domains#set_project_domain"
        post 'projects/:id/domain/check_availability', to: "domains#domain_is_available"
        put 'projects/:id/domain/google_tracking_id', to: "domains#set_google_tracking_id"

        # Links
        post 'projects/:id/links', to: "links#create_link"
        post 'projects/:id/links/search', to: "links#current_project_links"
        post 'projects/:id/links/search_v2', to: "links#current_project_links_v2"
        post 'projects/:id/links/by_ids', to: "links#links_by_ids"
        post 'projects/:id/links/check_path', to: "links#is_path_available"
        patch 'projects/:id/links/:link_id', to: "links#update_link"
        delete 'projects/:id/links/:link_id', to: "links#remove_link"
        get 'projects/:id/links/random_path', to: "links#generate_path"

        # Campaigns
        post 'projects/:id/campaigns', to: "campaigns#create"
        patch 'projects/:id/campaigns/:campaign_id', to: "campaigns#update"
        delete 'projects/:id/campaigns/:campaign_id', to: "campaigns#archive"
        post 'projects/:id/campaigns/search', to: "campaigns#current_project_campaigns"
        post 'projects/:id/campaigns/search_v2', to: "campaigns#current_project_campaigns_v2"
        post 'projects/:id/campaigns/metrics_overview', to: "campaigns#metrics_for_overview"

        # Events
        post 'projects/:id/events/search', to: "events#events_for_search_params"
        post 'projects/:id/events/sorted', to: "events#events_sorted_by_param"
        get 'projects/:id/events/metric_values', to: "events#metrics_values"
        post 'projects/:id/events/overview', to: "events#events_for_overview"
        post 'instances/:id/events/billing', to: "events#events_for_payment_screen"

        # Exports
        post 'projects/:id/exports/links', to: "export#export_link_data"
        post 'instances/:id/exports/usage', to: "export#export_usage_data"

        # Visitors
        post 'projects/:id/visitors/aggregated', to: "visitors#aggregated_visitors"
        post 'projects/:id/visitors/search', to: "visitors#visitors"
        get 'projects/:id/visitors/:visitor_id', to: "visitors#visitor_details"
        post 'projects/:id/visitors/aggregated_metrics', to: "visitors#aggregated_visitor_metrics_for_search_params"
        post 'projects/:id/visitors/metrics', to: "visitors#visitor_metrics_for_search_params"

        # Purchases (Enterprise)
        if ENV.fetch("GROVS_EE", "false") == "true"
          post 'projects/:id/purchases/search', to: "purchases#purchases"
          post 'projects/:id/purchases/revenue', to: "purchases#revenue_metrics"
        end

        # Dashboard
        post 'projects/:id/dashboard/metrics_overview', to: "dashboard#metrics_overview"
        post 'projects/:id/dashboard/links_views', to: "dashboard#links_views"
        post 'projects/:id/dashboard/top_links', to: "dashboard#best_performing_links"

        # Notifications
        get 'notifications/test'
        post 'projects/:project_id/notifications', to: "notifications#create"
        post 'projects/:project_id/notifications/search', to: "notifications#notifications"
        delete 'projects/:project_id/notifications/:id', to: "notifications#archive_notification"

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

        # Billing
        post 'instances/:id/billing/subscriptions', to: "payments#create_subscription_session"
        get 'instances/:id/billing/stripe_portal', to: "payments#stripe_dashboard_url"
        delete 'instances/:id/billing/subscription', to: "payments#cancel_subscription"
        get 'instances/:id/billing/subscription', to: "payments#subscription_details"
        get 'instances/:id/billing/mau', to: "payments#current_mau"
        get 'instances/:id/billing/usage', to: "payments#current_usage"

        # Automation (machine-to-machine, unchanged)
        post 'automation/metrics_for_user', to: "automation#metrics_for_user"
        post 'automation/details_for_link', to: "automation#details_for_link"

        # Admin (machine-to-machine, unchanged)
        post 'admin/create_enterprise_subscription', to: "admin#create_enterprise_subscription"
        patch 'admin/update_enterprise_subscription', to: "admin#update_enterprise_subscription"
        post 'admin/migrate_firebase_links', to: "admin#migrate_firebase_links"
        post 'admin/flush_events', to: "admin#flush_events"

        # Diagnostics (unchanged)
        get 'diagnostics/test_exception', to: "diagnostics#test_exception"
        post 'diagnostics/test_exception', to: "diagnostics#test_exception"
        get 'diagnostics/test_logs', to: "diagnostics#test_logs"
        post 'diagnostics/test_logs', to: "diagnostics#test_logs"
        get 'diagnostics/test_diagnostics', to: "diagnostics#test_diagnostics"
        post 'diagnostics/test_diagnostics', to: "diagnostics#test_diagnostics"

        # Webhooks (unchanged)
        post 'webhooks/stripe', to: "webhooks#stripe_webhook"
        post 'webhooks/send_stripe_quotas'

        # IAP (Enterprise)
        if ENV.fetch("GROVS_EE", "false") == "true"
          post 'iap/apple/production/:path', to: 'iap#apple_prod'
          post 'iap/apple/test/:path', to: 'iap#apple_test'
          post 'iap/google/:path', to: 'iap#google_handling'
        end

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
        post 'sdk/create_link', to: "sdk/links#create_link"

        # Events
        post 'sdk/event', to: "sdk/events#add_event"

        # Notifications
        post 'sdk/notifications_for_device', to: "sdk/notifications#notifications_for_device"
        get 'sdk/number_of_unread_notifications', to: "sdk/notifications#number_of_unread_notifications"
        post 'sdk/mark_notification_as_read', to: "sdk/notifications#mark_notification_as_read"
        get 'sdk/notifications_to_display_automatically', to: "sdk/notifications#notifications_to_display_automatically"

        # Visitors
        get 'sdk/visitor_attributes', to: "sdk/visitors#visitor_attributes"
        post 'sdk/visitor_attributes', to: "sdk/visitors#set_visitor_attributes"

        # Payments (Enterprise)
        if ENV.fetch("GROVS_EE", "false") == "true"
          post 'sdk/add_payment_event', to: "sdk/payments#add_payment_event"
        end

        # SERVER
        post 'sdk/generate_link', to: "server_sdk#generate_link"
        get 'sdk/link/:path', to: "server_sdk#link_details"
        get 'sdk/metrics_for_link/:path', to: 'server_sdk#metrics_for_link'
        get 'sdk/metrics_for_project', to: 'server_sdk#metrics_for_project'

      end
    end
  end

  # Legacy IAP webhook routes — kept for backward compatibility with Apple/Google webhook configurations
  namespace :api do
    namespace :v1 do
      if ENV.fetch("GROVS_EE", "false") == "true"
        # apple
        post 'iap/apple/production/:path', to: 'iap#apple_prod'
        # apple sandbox
        post 'iap/apple/test/:path', to: 'iap#apple_test'
        # google
        post 'iap/google/:path', to: 'iap#google_handling'
      end


      namespace :identity do
        namespace :sso do
          # OmniAuth callback route
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

  devise_for :users
  use_doorkeeper do
    controllers tokens: 'custom_tokens'
    skip_controllers :authorizations, :applications, :authorized_applications
  end
end
