require "test_helper"

class AuditCoverageTest < ActiveSupport::TestCase
  AUDITED = {
    "Api::V1::InstancesController#create_instance" => :exempt, # no tenant exists yet
    "Api::V1::InstancesController#edit_instance" => "instance.renamed",
    "Api::V1::InstancesController#delete_instance" => "instance.deletion_requested",
    "Api::V1::InstancesController#add_member_to_instance" => "instance.member_added",
    "Api::V1::InstancesController#remove_member_from_instance" => "instance.member_removed",
    "Api::V1::InstancesController#set_revenue_collection_enabled" => "instance.revenue_collection_changed",
    "Api::V1::InstancesController#dismiss_get_started" => :exempt,
    "Api::V1::InstancesController#complete_setup_step" => :exempt,
    "Api::V1::UsersController#create" => :exempt, # fresh sign-up: no instance to record against
    "Api::V1::UsersController#reset_password" => "user.password_reset_requested",
    "Api::V1::UsersController#change_password" => "user.password_changed",
    "Api::V1::UsersController#accept_invite" => "user.invite_accepted",
    "Api::V1::UsersController#edit_user" => :exempt,
    "Api::V1::UsersController#remove_user" => "user.account_deleted",
    "Api::V1::UsersController#otp_enabled" => :exempt,
    "Api::V1::UsersController#set_2fa_enabled" => %w[user.2fa_enabled user.2fa_disabled],
    "Api::V1::ConfigurationsController#set_ios_configuration" => "ios_configuration.updated",
    "Api::V1::ConfigurationsController#set_ios_push_configuration" => "ios_push_configuration.updated",
    "Api::V1::ConfigurationsController#set_android_configuration" => "android_configuration.updated",
    "Api::V1::ConfigurationsController#set_android_push_configuration" => "android_push_configuration.updated",
    "Api::V1::ConfigurationsController#set_android_api_access_key" => "android_api_access_key.updated",
    "Api::V1::ConfigurationsController#set_ios_api_access_key" => "ios_api_access_key.updated",
    "Api::V1::ConfigurationsController#set_desktop_configuration" => "desktop_configuration.updated",
    "Api::V1::ConfigurationsController#set_web_configuration" => "web_configuration.updated",
    "Api::V1::ConfigurationsController#remove_ios_configuration" => "ios_configuration.removed",
    "Api::V1::ConfigurationsController#remove_android_configuration" => "android_configuration.removed",
    "Api::V1::ConfigurationsController#remove_desktop_configuration" => "desktop_configuration.removed",
    "Api::V1::ConfigurationsController#remove_web_configuration" => "web_configuration.removed",
    "Api::V1::RedirectsController#set_redirect_config" => "redirect_config.updated",
    "Api::V1::RedirectsController#set_redirect" => "redirect.updated",
    "Api::V1::SmartBannersController#create" => "smart_banner.created",
    "Api::V1::SmartBannersController#update" => "smart_banner.updated",
    "Api::V1::SmartBannersController#destroy" => "smart_banner.deleted",
    "Api::V1::SmartBannersController#reorder" => "smart_banner.reordered",
    "Api::V1::SmartBannersController#duplicate" => "smart_banner.created",
    "Api::V1::DomainsController#set_project_domain" => "domain.updated",
    "Api::V1::DomainsController#set_google_tracking_id" => "domain.google_tracking_id_updated",
    "Api::V1::DomainsController#domain_is_available" => :exempt, # read-only POST
    "Api::V1::DomainsController#create_custom_domain" => "custom_domain.created",
    "Api::V1::DomainsController#delete_custom_domain" => "custom_domain.deleted",
    "Api::V1::DomainsController#create_custom_domain_v2" => "custom_domain.created",
    "Api::V1::DomainsController#delete_custom_domain_v2" => "custom_domain.deleted",
    "Api::V1::DomainsController#verify_custom_domain" => "custom_domain.verified",
    "Api::V1::LinksController#create_link" => "link.created",
    "Api::V1::LinksController#update_link" => "link.updated",
    "Api::V1::LinksController#remove_link" => "link.deleted",
    "Api::V1::LinksController#current_project_links" => :exempt, # read-only POST search
    "Api::V1::LinksController#current_project_links_v2" => :exempt,
    "Api::V1::LinksController#links_by_ids" => :exempt,
    "Api::V1::LinksController#is_path_available" => :exempt,
    "Api::V1::ExportController#export_link_data" => "export.link_data",
    "Api::V1::ExportController#export_usage_data" => "export.usage_data",
    "Api::V1::MigrationsController#create" => "migration_source.created",
    "Api::V1::MigrationSourcesController#update" => "migration_source.updated",
    "Api::V1::MigrationSourcesController#destroy" => "migration_source.deleted",
    "Api::V1::MigrationSourcesController#test" => :exempt,
    "Api::V1::Mcp::AuthController#approve_consent" => :exempt,
    "Api::V1::Mcp::AuthController#revoke_token" => "mcp_token.revoked",
    "Api::V1::Mcp::AuthController#revoke_token_by_id" => "mcp_token.revoked",
    "Api::V1::Mcp::LinksController#create" => "link.created",
    "Api::V1::Mcp::LinksController#update" => "link.updated",
    "Api::V1::Mcp::LinksController#archive" => "link.deleted",
    "Api::V1::Mcp::LinksController#index" => :exempt, # read-only POST search
    "Api::V1::Mcp::ConfigurationsController#setup_redirects" => "redirect_config.updated",
    "Api::V1::Mcp::ConfigurationsController#setup_sdk" =>
      %w[ios_configuration.updated android_configuration.updated desktop_configuration.updated],
    "Api::V1::Mcp::ProjectsController#create" => :exempt, # creates the tenant
    "Api::V1::Mcp::DashboardsController#create" => "dashboard.created",
    "Api::V1::Mcp::SegmentsController#create" => "segment.created",
    "Api::V1::AuditExportTokensController#create" => "audit_export_token.created",
    "Api::V1::AuditExportTokensController#destroy" => "audit_export_token.revoked",
    "Api::V1::EventDestinationsController#create" => "event_destination.created",
    "Api::V1::EventDestinationsController#update" => "event_destination.updated",
    "Api::V1::EventDestinationsController#destroy" => "event_destination.deleted",
    "Api::V1::EventDestinationsController#pause" => "event_destination.paused",
    "Api::V1::EventDestinationsController#resume" => "event_destination.resumed",
    "Api::V1::EventDestinationsController#rewind" => "event_destination.rewound",
    "Api::V1::EventDestinationsController#test" => "event_destination.tested",
    "Api::V1::EventDestinationsController#create_export" => "export.event_data",
    "Api::V1::EventStreamController#create_token" => "event_stream_token.created",
    "Api::V1::EventStreamController#destroy_token" => "event_stream_token.revoked",
    "Api::V1::DashboardsController#create" => "dashboard.created",
    "Api::V1::DashboardsController#update" => "dashboard.updated",
    "Api::V1::DashboardsController#destroy" => "dashboard.deleted",
    "Api::V1::DashboardsController#create_widget" => "dashboard.updated",
    "Api::V1::DashboardsController#update_widget" => "dashboard.updated",
    "Api::V1::DashboardsController#destroy_widget" => "dashboard.updated",
    "Api::V1::SegmentsController#create" => "segment.created",
    "Api::V1::SegmentsController#update" => "segment.updated",
    "Api::V1::SegmentsController#destroy" => "segment.archived",
    "Api::V1::SegmentsController#estimate" => :exempt, # read-only POST
    "Api::V1::SegmentsController#count" => :exempt, # read-only POST
    "Api::V1::SegmentsController#breakdown" => :exempt, # read-only POST
    "Api::V1::SegmentsController#users" => :exempt, # read-only POST
    "Api::V1::SegmentsController#export" => "segment.exported",
    "Api::V1::SegmentsController#identifier_list" => "segment.identifier_list_replaced",
    "Api::V1::SegmentsController#exports" => :exempt, # read-only GET
    "Api::V1::SegmentsController#export_status" => :exempt, # read-only GET
    "Api::V1::SegmentsController#fields" => :exempt, # read-only GET
    "Api::V1::PushCampaignsController#create" => "push_campaign.created",
    "Api::V1::PushCampaignsController#update" => "push_campaign.updated",
    "Api::V1::PushCampaignsController#send_now" => "push_campaign.scheduled",
    "Api::V1::PushCampaignsController#cancel" => "push_campaign.cancelled",
    "Api::V1::PushCampaignsController#send_winner" => "push_campaign.winner_sent",
    "Api::V1::PushCampaignsController#estimate" => :exempt, # read-only POST
    "Api::V1::PushCampaignsController#estimate_audience" => :exempt, # read-only POST
    "Api::V1::PushCampaignsController#remove_image" => "push_campaign.updated",
    "Api::V1::InAppCampaignsController#create" => "in_app_campaign.created",
    "Api::V1::InAppCampaignsController#update" => "in_app_campaign.updated",
    "Api::V1::InAppCampaignsController#destroy" => "in_app_campaign.deleted",
    "Api::V1::InAppCampaignsController#launch" => "in_app_campaign.launched",
    "Api::V1::InAppCampaignsController#pause" => "in_app_campaign.paused",
    "Api::V1::InAppCampaignsController#resume" => "in_app_campaign.resumed",
    "Api::V1::InAppCampaignsController#finish" => "in_app_campaign.ended",
    "Api::V1::InAppCampaignsController#duplicate" => "in_app_campaign.created",
    "Api::V1::InAppCampaignsController#update_audience" => "in_app_campaign.audience_updated",
    "Api::V1::InAppCampaignsController#test" => "in_app_campaign.tested",
    "Api::V1::InAppCampaignsController#upload_image" => "in_app_campaign.updated",
    "Api::V1::InAppCampaignsController#remove_image" => "in_app_campaign.updated",
    "Api::V1::InAppCampaignsController#media_index" => :exempt, # read-only GET
    "Api::V1::InAppCampaignsController#upload_media" => "in_app_campaign.updated",
    "Api::V1::InAppCampaignsController#remove_media" => "in_app_campaign.updated",
    "Api::V1::InAppSettingsController#update" => "in_app_settings.updated",
    "Api::V1::JourneysController#create" => "journey.created",
    "Api::V1::JourneysController#update" => "journey.updated",
    "Api::V1::JourneysController#destroy" => "journey.deleted",
    "Api::V1::JourneysController#launch" => "journey.launched",
    "Api::V1::JourneysController#pause" => "journey.paused",
    "Api::V1::JourneysController#resume" => "journey.resumed",
    "Api::V1::JourneysController#finish" => "journey.ended",
    "Api::V1::JourneysController#duplicate" => "journey.created",
    "Api::V1::JourneysController#upload_image" => "journey.updated",
    "Api::V1::SsoConnectionsController#upsert" =>
      %w[sso_connection.created sso_connection.updated sso_connection.enforce_enabled sso_connection.enforce_disabled],
    "Api::V1::SsoConnectionsController#destroy" => "sso_connection.deleted",
    "Api::V1::SsoConnectionsController#verify_domains" => "sso_connection.domain_verified",
    "Api::V1::SsoConnectionsController#create_scim_token" => "sso_connection.scim_token_rotated",
    "Api::V1::SsoConnectionsController#destroy_scim_token" => "sso_connection.scim_disabled",
    "Api::V1::AdminController#create_enterprise_subscription" => "enterprise_subscription.created",
    "Api::V1::AdminController#update_enterprise_subscription" => "enterprise_subscription.updated",
    "Api::V1::AdminController#create_custom_domain" => "custom_domain.created",
    "Api::V1::AdminController#migrate_firebase_links" => "links.firebase_imported",
    "Api::V1::AdminController#flush_events" => :exempt, # global, operator log only
    "Api::V1::AdminController#update_instance_retention" => "instance.retention_changed"
  }.freeze

  # Read-only POST searches, content (campaigns), billing UI, inbound webhooks, diagnostics (Q15).
  EXEMPT_CONTROLLERS = %w[
    Api::V1::DashboardController Api::V1::EventsController Api::V1::VisitorsController
    Api::V1::CampaignsController Api::V1::PaymentsController
    Api::V1::AutomationController Api::V1::DiagnosticsController Api::V1::WebhooksController
    Api::V1::IapController Api::V1::PurchasesController Api::V1::ServerSdkController
    Api::V1::Mcp::CampaignsController Api::V1::Mcp::AnalyticsController
  ].freeze

  # MCP reads go over POST because the client only sends JSON bodies; only their creates are audited.
  MCP_READ_CONTROLLERS = %w[
    Api::V1::Mcp::Analytics::QueryController Api::V1::Mcp::Analytics::OverviewController
    Api::V1::Mcp::Analytics::RetentionController Api::V1::Mcp::Analytics::EventsExplorerController
    Api::V1::Mcp::DashboardsController Api::V1::Mcp::SegmentsController Api::V1::Mcp::PushCampaignsController
    Api::V1::Mcp::InAppCampaignsController Api::V1::Mcp::JourneysController
  ].freeze

  test "every mutating dashboard/admin route is in the audit map" do
    mutating = Rails.application.routes.routes.filter_map do |r|
      verb = r.verb.to_s
      next unless verb.match?(/POST|PUT|PATCH|DELETE/)

      controller = r.defaults[:controller]
      action = r.defaults[:action]
      next unless controller&.start_with?("api/v1/")
      next if controller.start_with?("api/v1/sdk/", "api/v1/analytics/", "api/v1/identity/")

      "#{controller.camelize}Controller##{action}"
    end.uniq

    # A server API subclass audits exactly like its dashboard parent.
    missing = mutating.reject do |key|
      AUDITED.key?(key.sub("::Server::", "::")) || (EXEMPT_CONTROLLERS + MCP_READ_CONTROLLERS).include?(key.split("#").first)
    end
    assert_empty missing, "Mutating routes with no audit decision: #{missing.inspect}"
  end

  # setup_sdk builds "#{platform}_configuration.updated" at runtime, hence the interpolation check.
  test "every audited action name in the map is a fixed string in the controller source" do
    AUDITED.each do |key, actions|
      next if actions == :exempt

      klass = key.split("#").first.constantize
      # An MCP subclass inherits the parent's action, so the parent's source counts too.
      source = [klass, klass.superclass].map do |k|
        path = k.name.sub("Controller", "").underscore
        file = %w[app ee/app].map { |d| Rails.root.join("#{d}/controllers/#{path}_controller.rb") }.find(&:exist?)
        file ? File.read(file) : ""
      end.join
      if key == "Api::V1::Mcp::ConfigurationsController#setup_sdk"
        assert_includes source, "\#{platform}_configuration.updated", "#{key} does not build the platform audit action"
      else
        Array(actions).each do |name|
          assert_includes source, "#{name}\"", "#{key} does not reference audit action #{name}"
        end
      end
    end
  end

  test "every action name in the map is in the catalogue" do
    names = AUDITED.values.reject { |v| v == :exempt }.flatten
    assert_empty names - AuditEvent::ACTIONS
  end
end
