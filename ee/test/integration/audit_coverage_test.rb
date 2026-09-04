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
    "Api::V1::UsersController#create" => "user.invite_accepted",
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
    "Api::V1::AuditExportTokensController#create" => "audit_export_token.created",
    "Api::V1::AuditExportTokensController#destroy" => "audit_export_token.revoked",
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

  # Read-only POST searches, content (campaigns/notifications), billing UI, inbound webhooks, diagnostics (Q15).
  EXEMPT_CONTROLLERS = %w[
    Api::V1::DashboardController Api::V1::EventsController Api::V1::VisitorsController
    Api::V1::CampaignsController Api::V1::NotificationsController Api::V1::PaymentsController
    Api::V1::AutomationController Api::V1::DiagnosticsController Api::V1::WebhooksController
    Api::V1::IapController Api::V1::PurchasesController Api::V1::ServerSdkController
    Api::V1::Mcp::CampaignsController Api::V1::Mcp::AnalyticsController
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

    missing = mutating.reject { |key| AUDITED.key?(key) || EXEMPT_CONTROLLERS.include?(key.split("#").first) }
    assert_empty missing, "Mutating routes with no audit decision: #{missing.inspect}"
  end

  # setup_sdk builds "#{platform}_configuration.updated" at runtime, hence the interpolation check.
  test "every audited action name in the map is a fixed string in the controller source" do
    AUDITED.each do |key, actions|
      next if actions == :exempt

      controller = key.split("#").first.sub("Controller", "").underscore
      source = File.read(%w[app ee/app].map { |d| Rails.root.join("#{d}/controllers/#{controller}_controller.rb") }.find(&:exist?))
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
