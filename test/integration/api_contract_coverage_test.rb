require "test_helper"
require_relative "analytics_schema_helper"
require_relative "analytics_schema_contract_test"

# Coverage gate for the strict API contract lock (see test/support/api_contracts.rb).
#
# Enumerates every app API endpoint (Controller#action under api/ and public/) and
# asserts each one is EITHER covered by a registered contract OR explicitly listed
# in PENDING below. This makes "all endpoints" enforceable, not aspirational:
#   - add a new endpoint without a contract  -> fails (must contract it or add to PENDING)
#   - write a contract                        -> remove the line from PENDING (else fails)
#   - delete/rename an endpoint               -> stale PENDING entry fails
#
# PENDING is the shrinking backlog. The goal is PENDING == [].
class ApiContractCoverageTest < ActiveSupport::TestCase
  EE_ONLY_ENDPOINTS = %w[
    Api::V1::IapController#apple_prod
    Api::V1::IapController#apple_test
    Api::V1::IapController#google_handling
    Api::V1::PurchasesController#purchases
    Api::V1::PurchasesController#revenue_metrics
    Api::V1::Sdk::PaymentsController#add_payment_event
    Api::V1::AuditEventsController#index
    Api::V1::AuditEventsController#latest
    Api::V1::AuditExportTokensController#index
    Api::V1::AuditExportTokensController#create
    Api::V1::AuditExportTokensController#destroy
    Api::V1::SsoConnectionsController#show
    Api::V1::SsoConnectionsController#upsert
    Api::V1::SsoConnectionsController#destroy
    Api::V1::SsoConnectionsController#verify_domains
    Api::V1::SsoConnectionsController#create_scim_token
    Api::V1::SsoConnectionsController#destroy_scim_token
    Api::V1::EventDestinationsController#index
    Api::V1::EventDestinationsController#create
    Api::V1::EventDestinationsController#update
    Api::V1::EventDestinationsController#destroy
    Api::V1::EventDestinationsController#pause
    Api::V1::EventDestinationsController#resume
    Api::V1::EventDestinationsController#rewind
    Api::V1::EventDestinationsController#test
    Api::V1::EventDestinationsController#create_export
    Api::V1::EventStreamController#index
    Api::V1::EventStreamController#tokens
    Api::V1::EventStreamController#create_token
    Api::V1::EventStreamController#destroy_token
    Api::V1::SegmentsController#index
    Api::V1::SegmentsController#fields
    Api::V1::SegmentsController#show
    Api::V1::SegmentsController#create
    Api::V1::SegmentsController#update
    Api::V1::SegmentsController#destroy
    Api::V1::SegmentsController#estimate
    Api::V1::SegmentsController#count
    Api::V1::SegmentsController#identifier_list
    Api::V1::SegmentsController#identifier_list_preview
    Api::V1::SegmentsController#identifier_list_download
    Api::V1::SegmentsController#breakdown
    Api::V1::SegmentsController#users
    Api::V1::SegmentsController#export
    Api::V1::SegmentsController#exports
    Api::V1::SegmentsController#export_status
    Api::V1::SegmentsController#size_history
    Api::V1::PushCampaignsController#index
    Api::V1::PushCampaignsController#show
    Api::V1::PushCampaignsController#create
    Api::V1::PushCampaignsController#update
    Api::V1::PushCampaignsController#send_now
    Api::V1::PushCampaignsController#cancel
    Api::V1::PushCampaignsController#send_winner
    Api::V1::PushCampaignsController#experiment
    Api::V1::PushCampaignsController#estimate
    Api::V1::PushCampaignsController#estimate_audience
    Api::V1::PushCampaignsController#deliveries
    Api::V1::PushCampaignsController#remove_image
    Api::V1::InAppCampaignsController#index
    Api::V1::InAppCampaignsController#show
    Api::V1::InAppCampaignsController#create
    Api::V1::InAppCampaignsController#update
    Api::V1::InAppCampaignsController#destroy
    Api::V1::InAppCampaignsController#launch
    Api::V1::InAppCampaignsController#pause
    Api::V1::InAppCampaignsController#resume
    Api::V1::InAppCampaignsController#finish
    Api::V1::InAppCampaignsController#duplicate
    Api::V1::InAppCampaignsController#update_audience
    Api::V1::InAppCampaignsController#test
    Api::V1::InAppCampaignsController#report
    Api::V1::InAppCampaignsController#answers
    Api::V1::InAppCampaignsController#comments
    Api::V1::InAppCampaignsController#experiment
    Api::V1::InAppCampaignsController#upload_image
    Api::V1::InAppCampaignsController#remove_image
    Api::V1::InAppCampaignsController#media_index
    Api::V1::InAppCampaignsController#upload_media
    Api::V1::InAppCampaignsController#remove_media
    Api::V1::InAppSettingsController#show
    Api::V1::InAppSettingsController#update
    Public::InAppPreviewController#show
    Api::V1::Sdk::InAppController#sync
    Api::V1::JourneysController#index
    Api::V1::JourneysController#show
    Api::V1::JourneysController#create
    Api::V1::JourneysController#update
    Api::V1::JourneysController#destroy
    Api::V1::JourneysController#launch
    Api::V1::JourneysController#pause
    Api::V1::JourneysController#resume
    Api::V1::JourneysController#finish
    Api::V1::JourneysController#duplicate
    Api::V1::JourneysController#report
    Api::V1::JourneysController#upload_image
    Api::V1::Mcp::SegmentsController#index
    Api::V1::Mcp::SegmentsController#fields
    Api::V1::Mcp::SegmentsController#estimate
    Api::V1::Mcp::SegmentsController#create
    Api::V1::Mcp::SegmentsController#breakdown
    Api::V1::Mcp::PushCampaignsController#index
    Api::V1::Mcp::PushCampaignsController#show
    Api::V1::Mcp::PushCampaignsController#experiment
    Api::V1::Mcp::InAppCampaignsController#index
    Api::V1::Mcp::InAppCampaignsController#show
    Api::V1::Mcp::InAppCampaignsController#report
    Api::V1::Mcp::InAppCampaignsController#experiment
    Api::V1::Mcp::InAppCampaignsController#comments
    Api::V1::Mcp::JourneysController#index
    Api::V1::Mcp::JourneysController#report
    Api::V1::Server::SegmentsController#index
    Api::V1::Server::SegmentsController#fields
    Api::V1::Server::SegmentsController#estimate
    Api::V1::Server::SegmentsController#create
    Api::V1::Server::SegmentsController#show
    Api::V1::Server::SegmentsController#update
    Api::V1::Server::SegmentsController#destroy
    Api::V1::Server::SegmentsController#count
    Api::V1::Server::SegmentsController#identifier_list
    Api::V1::Server::InAppCampaignsController#index
    Api::V1::Server::InAppCampaignsController#create
    Api::V1::Server::InAppCampaignsController#show
    Api::V1::Server::InAppCampaignsController#update
    Api::V1::Server::InAppCampaignsController#destroy
    Api::V1::Server::InAppCampaignsController#launch
    Api::V1::Server::InAppCampaignsController#pause
    Api::V1::Server::InAppCampaignsController#resume
    Api::V1::Server::InAppCampaignsController#finish
    Api::V1::Server::InAppCampaignsController#test
    Api::V1::Server::InAppCampaignsController#report
  ].freeze

  # No endpoint may sit outside the contract registry. If an endpoint cannot be
  # contracted, the escape hatch belongs in that endpoint's contract with an
  # explicit :any response for the non-JSON/framework-owned case.
  PENDING = [].freeze

  DYNAMIC_SCHEMA_ALLOWLIST = [
    "Api::V1::IapController#apple_prod 200 response",
    "Api::V1::IapController#apple_prod request",
    "Api::V1::IapController#apple_test 200 response",
    "Api::V1::IapController#apple_test request",
    "Api::V1::IapController#google_handling 200 response",
    "Api::V1::IapController#google_handling request",
    "Api::V1::Sdk::PaymentsController#add_payment_event 200 response",
    "Api::V1::Sdk::PaymentsController#add_payment_event request",
    "Api::V1::WebhooksController#stripe_webhook request"
  ].freeze

  NESTED_FLEXIBLE_SCHEMA_ALLOWLIST = [
    "Api::V1::Sdk::EventsController#add_event request.properties.properties",
    "Api::V1::Sdk::EventsController#add_custom_event request.properties.properties",
    "Api::V1::AdminController#create_enterprise_subscription 201 response.properties.subscription.additionalProperties",
    "Api::V1::AdminController#migrate_firebase_links request.properties.file",
    "Api::V1::AdminController#update_enterprise_subscription 200 response.properties.subscription.additionalProperties",
    "Api::V1::AuditEventsController#index 200 response.properties.events.items.properties.changes",
    "Api::V1::AuditEventsController#index 200 response.properties.events.items.properties.target",
    "Api::V1::SmartBannersController#create request.properties.smart_banner.properties.icon",
    "Api::V1::SmartBannersController#update request.properties.smart_banner.properties.icon",
    "Api::V1::SsoConnectionsController#upsert request.properties.sso_connection",
    "Api::V1::AutomationController#details_for_link 200 response.properties.link.properties.data",
    "Api::V1::AutomationController#details_for_link 200 response.properties.link.properties.image",
    "Api::V1::AutomationController#details_for_link request.properties.automation.additionalProperties",
    "Api::V1::AutomationController#metrics_for_user request.properties.automation.additionalProperties",
    "Api::V1::CampaignsController#current_project_campaigns 400 response.oneOf[1].properties.traces",
    "Api::V1::CampaignsController#current_project_campaigns_v2 400 response.oneOf[1].properties.traces",
    "Api::V1::ConfigurationsController#current_project_configurations 200 response.properties.configurations.items.properties.configuration",
    "Api::V1::ConfigurationsController#set_android_api_access_key request.properties.file",
    "Api::V1::ConfigurationsController#set_android_push_configuration request.properties.push_certificate",
    "Api::V1::ConfigurationsController#set_ios_api_access_key request.properties.file",
    "Api::V1::ConfigurationsController#set_ios_push_configuration request.properties.push_certificate",
    "Api::V1::DashboardController#best_performing_links 200 response.properties.links.items.properties.data",
    "Api::V1::DashboardController#best_performing_links 200 response.properties.links.items.properties.image",
    "Api::V1::DiagnosticsController#test_exception 404 response.oneOf[1].properties.traces",
    "Api::V1::DiagnosticsController#test_exception 500 response.properties.traces",
    "Api::V1::DomainsController#set_project_domain request.properties.generic_image",
    "Api::V1::EventDestinationsController#create request.properties.credentials.properties.headers",
    "Api::V1::EventDestinationsController#update request.properties.credentials.properties.headers",
    "Api::V1::EventStreamController#index 200 response.properties.events.items",
    "Api::V1::EventsController#events_sorted_by_param 200 response.oneOf[0].items.properties.link.properties.data",
    "Api::V1::EventsController#events_sorted_by_param 200 response.oneOf[1].properties.result.items.properties.link.properties.data",
    "Api::V1::EventsController#events_for_search_params 400 response.oneOf[1].properties.traces",
    "Api::V1::EventsController#events_sorted_by_param 400 response.oneOf[1].properties.traces",
    "Api::V1::LinksController#create_link 200 response.properties.link.properties.data",
    "Api::V1::LinksController#create_link 200 response.properties.link.properties.image",
    "Api::V1::LinksController#create_link request.properties.android_custom_redirect",
    "Api::V1::LinksController#create_link request.properties.data",
    "Api::V1::LinksController#create_link request.properties.desktop_custom_redirect",
    "Api::V1::LinksController#create_link request.properties.image",
    "Api::V1::LinksController#create_link request.properties.ios_custom_redirect",
    "Api::V1::LinksController#current_project_links 400 response.oneOf[1].properties.traces",
    "Api::V1::LinksController#current_project_links_v2 200 response.properties.links.items.properties.data",
    "Api::V1::LinksController#current_project_links_v2 400 response.oneOf[1].properties.traces",
    "Api::V1::LinksController#links_by_ids 200 response.properties.links.items.properties.data",
    "Api::V1::LinksController#links_by_ids 200 response.properties.links.items.properties.image",
    "Api::V1::LinksController#lookup 200 response.properties.links.items.properties.data",
    "Api::V1::LinksController#lookup 200 response.properties.links.items.properties.image",
    "Api::V1::LinksController#update_link 200 response.properties.link.properties.data",
    "Api::V1::LinksController#update_link 200 response.properties.link.properties.image",
    "Api::V1::LinksController#update_link request.properties.android_custom_redirect",
    "Api::V1::LinksController#update_link request.properties.data",
    "Api::V1::LinksController#update_link request.properties.desktop_custom_redirect",
    "Api::V1::LinksController#update_link request.properties.image",
    "Api::V1::LinksController#update_link request.properties.ios_custom_redirect",
    "Api::V1::Mcp::DashboardsController#create request.properties.widgets",
    "Api::V1::Mcp::AnalyticsController#link_stats 200 response.properties.metrics",
    "Api::V1::Mcp::AnalyticsController#link_stats 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::AnalyticsController#project_metrics 200 response.properties.metrics",
    "Api::V1::Mcp::AnalyticsController#project_metrics 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::AnalyticsController#top_links 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::AuthController#approve_consent 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::AuthController#usage 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::CampaignsController#archive 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::CampaignsController#create 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::CampaignsController#index 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::ConfigurationsController#setup_redirects 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::ConfigurationsController#setup_sdk 200 response.properties.configurations.additionalProperties.properties.configuration",
    "Api::V1::Mcp::ConfigurationsController#setup_sdk 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::LinksController#archive 200 response.properties.link.properties.data",
    "Api::V1::Mcp::LinksController#archive 200 response.properties.link.properties.image",
    "Api::V1::Mcp::LinksController#archive 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::LinksController#create 201 response.properties.link.properties.data",
    "Api::V1::Mcp::LinksController#create 201 response.properties.link.properties.image",
    "Api::V1::Mcp::LinksController#create 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::LinksController#create request.properties.data",
    "Api::V1::Mcp::LinksController#create request.properties.image",
    "Api::V1::Mcp::LinksController#index 200 response.properties.links.items.properties.data",
    "Api::V1::Mcp::LinksController#index 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::LinksController#show 200 response.properties.link.properties.data",
    "Api::V1::Mcp::LinksController#show 200 response.properties.link.properties.image",
    "Api::V1::Mcp::LinksController#show 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::LinksController#update 200 response.properties.link.properties.data",
    "Api::V1::Mcp::LinksController#update 200 response.properties.link.properties.image",
    "Api::V1::Mcp::LinksController#update 400 response.oneOf[1].properties.traces",
    "Api::V1::Mcp::LinksController#update request.properties.data",
    "Api::V1::Mcp::LinksController#update request.properties.image",
    "Api::V1::Mcp::ProjectsController#create 400 response.oneOf[1].properties.traces",
    "Api::V1::PaymentsController#subscription_details 200 response.oneOf[0].properties.stripe_subscription.additionalProperties",
    "Api::V1::RedirectsController#redirect_config 200 response.properties.redirect_config.additionalProperties",
    "Api::V1::RedirectsController#set_redirect 200 response.properties.config.additionalProperties",
    "Api::V1::RedirectsController#set_redirect_config 200 response.properties.redirect_config.additionalProperties",
    "Api::V1::SegmentsController#create 201 response.properties.segment.properties.definition",
    "Api::V1::SegmentsController#create request.properties.definition",
    "Api::V1::SegmentsController#fields 200 response.properties.conditions.items",
    "Api::V1::SegmentsController#estimate request.properties.definition",
    "Api::V1::SegmentsController#identifier_list request.properties.identifiers",
    "Api::V1::SegmentsController#identifier_list request.properties.file",
    "Api::V1::SegmentsController#identifier_list 200 response.properties.segment.properties.definition",
    "Api::V1::SegmentsController#index 200 response.properties.segments.items.properties.definition",
    "Api::V1::SegmentsController#show 200 response.properties.segment.properties.definition",
    "Api::V1::SegmentsController#update 200 response.properties.segment.properties.definition",
    "Api::V1::SegmentsController#update request.properties.definition",
    "Api::V1::PushCampaignsController#cancel 200 response.properties.push_campaign.properties.data",
    "Api::V1::PushCampaignsController#cancel 200 response.properties.push_campaign.properties.report.properties.error_counts",
    "Api::V1::PushCampaignsController#send_winner 202 response.properties.push_campaign.properties.data",
    "Api::V1::PushCampaignsController#send_winner 202 response.properties.push_campaign.properties.report.properties.error_counts",
    "Api::V1::PushCampaignsController#create 201 response.properties.push_campaign.properties.data",
    "Api::V1::PushCampaignsController#create 201 response.properties.push_campaign.properties.report.properties.error_counts",
    "Api::V1::PushCampaignsController#send_now 202 response.properties.push_campaign.properties.data",
    "Api::V1::PushCampaignsController#send_now 202 response.properties.push_campaign.properties.report.properties.error_counts",
    "Api::V1::PushCampaignsController#show 200 response.properties.push_campaign.properties.data",
    "Api::V1::PushCampaignsController#show 200 response.properties.push_campaign.properties.report.properties.error_counts",
    "Api::V1::PushCampaignsController#update 200 response.properties.push_campaign.properties.data",
    "Api::V1::PushCampaignsController#update 200 response.properties.push_campaign.properties.report.properties.error_counts",
    "Api::V1::PushCampaignsController#index 200 response.properties.push_campaigns.items.properties.data",
    "Api::V1::PushCampaignsController#index 200 response.properties.push_campaigns.items.properties.report.properties.error_counts",
    "Api::V1::PushCampaignsController#create request.properties.data",
    "Api::V1::PushCampaignsController#update request.properties.data",
    "Api::V1::PushCampaignsController#create request.properties.image",
    "Api::V1::PushCampaignsController#update request.properties.image",
    "Api::V1::PushCampaignsController#remove_image 200 response.properties.push_campaign.properties.data",
    "Api::V1::PushCampaignsController#remove_image 200 response.properties.push_campaign.properties.report.properties.error_counts",
    "Api::V1::InAppCampaignsController#create 201 response.properties.in_app_campaign.properties.caps",
    "Api::V1::InAppCampaignsController#create 201 response.properties.in_app_campaign.properties.content",
    "Api::V1::InAppCampaignsController#create 201 response.properties.in_app_campaign.properties.schedule",
    "Api::V1::InAppCampaignsController#duplicate 201 response.properties.in_app_campaign.properties.caps",
    "Api::V1::InAppCampaignsController#duplicate 201 response.properties.in_app_campaign.properties.content",
    "Api::V1::InAppCampaignsController#duplicate 201 response.properties.in_app_campaign.properties.schedule",
    "Api::V1::InAppCampaignsController#finish 200 response.properties.in_app_campaign.properties.caps",
    "Api::V1::InAppCampaignsController#finish 200 response.properties.in_app_campaign.properties.content",
    "Api::V1::InAppCampaignsController#finish 200 response.properties.in_app_campaign.properties.schedule",
    "Api::V1::InAppCampaignsController#launch 202 response.properties.in_app_campaign.properties.caps",
    "Api::V1::InAppCampaignsController#launch 202 response.properties.in_app_campaign.properties.content",
    "Api::V1::InAppCampaignsController#launch 202 response.properties.in_app_campaign.properties.schedule",
    "Api::V1::InAppCampaignsController#pause 200 response.properties.in_app_campaign.properties.caps",
    "Api::V1::InAppCampaignsController#pause 200 response.properties.in_app_campaign.properties.content",
    "Api::V1::InAppCampaignsController#pause 200 response.properties.in_app_campaign.properties.schedule",
    "Api::V1::InAppCampaignsController#resume 200 response.properties.in_app_campaign.properties.caps",
    "Api::V1::InAppCampaignsController#resume 200 response.properties.in_app_campaign.properties.content",
    "Api::V1::InAppCampaignsController#resume 200 response.properties.in_app_campaign.properties.schedule",
    "Api::V1::InAppCampaignsController#update_audience 202 response.properties.in_app_campaign.properties.caps",
    "Api::V1::InAppCampaignsController#update_audience 202 response.properties.in_app_campaign.properties.content",
    "Api::V1::InAppCampaignsController#update_audience 202 response.properties.in_app_campaign.properties.schedule",
    "Api::V1::InAppCampaignsController#show 200 response.properties.in_app_campaign.properties.caps",
    "Api::V1::InAppCampaignsController#show 200 response.properties.in_app_campaign.properties.content",
    "Api::V1::InAppCampaignsController#show 200 response.properties.in_app_campaign.properties.schedule",
    "Api::V1::InAppCampaignsController#update 200 response.properties.in_app_campaign.properties.caps",
    "Api::V1::InAppCampaignsController#update 200 response.properties.in_app_campaign.properties.content",
    "Api::V1::InAppCampaignsController#update 200 response.properties.in_app_campaign.properties.schedule",
    "Api::V1::InAppCampaignsController#index 200 response.properties.in_app_campaigns.items.properties.caps",
    "Api::V1::InAppCampaignsController#index 200 response.properties.in_app_campaigns.items.properties.content",
    "Api::V1::InAppCampaignsController#index 200 response.properties.in_app_campaigns.items.properties.schedule",
    "Api::V1::InAppCampaignsController#create request.properties.lock_version",
    "Api::V1::InAppCampaignsController#update request.properties.lock_version",
    "Api::V1::InAppCampaignsController#create request.properties.caps",
    "Api::V1::InAppCampaignsController#create request.properties.conditions",
    "Api::V1::InAppCampaignsController#create request.properties.content",
    "Api::V1::InAppCampaignsController#create request.properties.schedule",
    "Api::V1::InAppCampaignsController#create request.properties.triggers",
    "Api::V1::InAppCampaignsController#update request.properties.caps",
    "Api::V1::InAppCampaignsController#update request.properties.conditions",
    "Api::V1::InAppCampaignsController#update request.properties.content",
    "Api::V1::InAppCampaignsController#update request.properties.schedule",
    "Api::V1::InAppCampaignsController#update request.properties.triggers",
    "Api::V1::PushCampaignsController#create request.properties.conversion",
    "Api::V1::PushCampaignsController#create request.properties.variants",
    "Api::V1::PushCampaignsController#update request.properties.conversion",
    "Api::V1::PushCampaignsController#update request.properties.variants",
    "Api::V1::InAppCampaignsController#create request.properties.conversion",
    "Api::V1::InAppCampaignsController#create request.properties.variants",
    "Api::V1::InAppCampaignsController#update request.properties.conversion",
    "Api::V1::InAppCampaignsController#update request.properties.variants",
    "Api::V1::InAppCampaignsController#remove_image 200 response.properties.in_app_campaign.properties.caps",
    "Api::V1::InAppCampaignsController#remove_image 200 response.properties.in_app_campaign.properties.content",
    "Api::V1::InAppCampaignsController#remove_image 200 response.properties.in_app_campaign.properties.schedule",
    "Api::V1::InAppCampaignsController#upload_image 200 response.properties.in_app_campaign.properties.caps",
    "Api::V1::InAppCampaignsController#upload_image 200 response.properties.in_app_campaign.properties.content",
    "Api::V1::InAppCampaignsController#upload_image 200 response.properties.in_app_campaign.properties.schedule",
    "Api::V1::InAppCampaignsController#upload_image request.properties.image",
    "Api::V1::InAppCampaignsController#upload_media request.properties.file",
    "Api::V1::JourneysController#upload_image request.properties.image",
    "Api::V1::JourneysController#upload_image request.properties.lock_version",
    "Api::V1::Sdk::InAppController#sync 200 response.oneOf[1].properties.campaigns.items",
    "Api::V1::Sdk::InAppController#sync 200 response.oneOf[1].properties.test_messages.items",
    "Api::V1::ServerSdkController#push 202 response.properties.campaign.properties.data",
    "Api::V1::ServerSdkController#push 202 response.properties.campaign.properties.report.properties.error_counts",
    "Api::V1::ServerSdkController#push request.properties.data",
    "Api::V1::ServerSdkController#push_status 200 response.properties.campaign.properties.data",
    "Api::V1::ServerSdkController#push_status 200 response.properties.campaign.properties.report.properties.error_counts",
    "Api::V1::SegmentsController#users request.properties.limit",
    "Api::V1::Sdk::LinksController#create_link request.properties.android_custom_redirect",
    "Api::V1::Sdk::LinksController#create_link request.properties.data",
    "Api::V1::Sdk::LinksController#create_link request.properties.desktop_custom_redirect",
    "Api::V1::Sdk::LinksController#create_link request.properties.image",
    "Api::V1::Sdk::LinksController#create_link request.properties.ios_custom_redirect",
    "Api::V1::Sdk::LinksController#data_for_device_details 200 response.properties.data",
    "Api::V1::Sdk::LinksController#data_for_device_details_and_path 200 response.properties.data",
    "Api::V1::Sdk::LinksController#data_for_device_details_and_url 200 response.properties.data",
    "Api::V1::Sdk::LinksController#link_details 200 response.properties.data",
    "Api::V1::Sdk::LinksController#link_details 200 response.properties.image",
    "Api::V1::Sdk::SmartBannersController#link request.properties.data",
    "Api::V1::Sdk::SmartBannersController#link request.properties.page_path",
    "Api::V1::ServerSdkController#generate_link request.properties.android_custom_redirect",
    "Api::V1::ServerSdkController#generate_link request.properties.data",
    "Api::V1::ServerSdkController#generate_link request.properties.desktop_custom_redirect",
    "Api::V1::ServerSdkController#generate_link request.properties.image",
    "Api::V1::ServerSdkController#generate_link request.properties.ios_custom_redirect",
    "Api::V1::ServerSdkController#link_details 200 response.properties.link.properties.data",
    "Api::V1::ServerSdkController#link_details 200 response.properties.link.properties.image",
    "Api::V1::ServerSdkController#metrics_for_link 200 response.properties.metrics.properties.data",
    "Api::V1::ServerSdkController#metrics_for_project 200 response.items.properties.data",
    "Api::V1::UsersController#change_password request.properties.user",
    "Api::V1::DashboardsController#create_widget request.properties.query",
    "Api::V1::DashboardsController#create_widget 200 response.properties.widget.properties.query",
    "Api::V1::DashboardsController#update_widget request.properties.query",
    "Api::V1::DashboardsController#update_widget 200 response.properties.widget.properties.query",
    "Api::V1::DashboardsController#create 200 response.properties.dashboard.properties.widgets.items.properties.query",
    "Api::V1::DashboardsController#index 200 response.properties.dashboards.items.properties.widgets.items.properties.query",
    "Api::V1::DashboardsController#update 200 response.properties.dashboard.properties.widgets.items.properties.query",
    "Public::PublicLinkController#create request.properties.data",
    "Public::PublicLinkController#create request.properties.image"
  ].freeze

  test "every app API endpoint is contracted or explicitly pending" do
    uncontracted = app_endpoints - ApiContracts.actions

    new_uncovered = (uncontracted - PENDING).sort      # endpoints with no contract and not triaged
    resolved_or_stale = (PENDING - uncontracted).reject { |endpoint| ee_only_endpoint_in_oss_mode?(endpoint) }.sort

    assert new_uncovered.empty? && resolved_or_stale.empty?, <<~MSG
      API contract coverage drift.

      Endpoints with NO contract and NOT in PENDING (add a contract, or add to PENDING):
        #{new_uncovered.empty? ? '(none)' : new_uncovered.join("\n    ")}

      PENDING entries that are now contracted or no longer exist (remove from PENDING):
        #{resolved_or_stale.empty? ? '(none)' : resolved_or_stale.join("\n    ")}

      Locked so far: #{ApiContracts.actions.size}/#{app_endpoints.size} endpoints. Backlog: #{uncontracted.size}.
    MSG
  end

  test "every registered contract maps to a real endpoint" do
    unknown = ApiContracts.actions - app_endpoints
    assert unknown.empty?, "Contracts registered for non-existent endpoints (typo in the key?):\n  #{unknown.join("\n  ")}"
  end

  # The analytics namespace is excluded from the ApiContracts coverage gate
  # because it is governed by AnalyticsSchemaContractTest instead. This guard
  # makes that delegation airtight: every live analytics route MUST appear in
  # AnalyticsSchemaHelper::INPUT_SCHEMA_TO_ACTION. Adding an analytics route
  # without a schema mapping fails here.
  test "every analytics endpoint has an INPUT_SCHEMA mapping" do
    mapped = AnalyticsSchemaContractTest::INPUT_SCHEMA_TO_ACTION.values.to_set
    unmapped = analytics_endpoints.reject { |klass, action| mapped.include?([klass, action]) || mapped.include?([klass.superclass, action]) }

    assert unmapped.empty?, <<~MSG
      Analytics endpoint(s) with no INPUT_SCHEMA mapping. The api/v1/analytics/
      namespace is governed by AnalyticsSchemaContractTest, so every route must
      be registered in AnalyticsSchemaHelper::INPUT_SCHEMAS and wired into
      AnalyticsSchemaContractTest::INPUT_SCHEMA_TO_ACTION:
        #{unmapped.empty? ? '(none)' : unmapped.map { |k, a| "#{k}##{a}" }.join("\n    ")}
    MSG
  end

  test "contracts do not use unreviewed broad top-level schemas" do
    loose = ApiContracts.contracts.flat_map do |action, contract|
      entries = []
      entries << "#{action} request" if broad_schema?(contract.request)
      contract.responses.each do |status, schema|
        entries << "#{action} #{status} response" if raw_unchecked?(schema) || broad_schema?(schema)
      end
      entries
    end

    assert loose.empty?, "Broad top-level API contracts must be replaced with endpoint schemas or explicitly allowlisted:\n  #{loose.join("\n  ")}"
  end

  test "dynamic top-level schemas are explicitly allowlisted" do
    dynamic = ApiContracts.contracts.flat_map do |action, contract|
      entries = []
      entries << "#{action} request" if dynamic_schema?(contract.request)
      contract.responses.each do |status, schema|
        entries << "#{action} #{status} response" if dynamic_schema?(schema)
      end
      entries
    end.sort

    expected = active_allowlist(DYNAMIC_SCHEMA_ALLOWLIST)
    unreviewed = dynamic - expected
    stale = expected - dynamic

    assert unreviewed.empty? && stale.empty?, <<~MSG
      Dynamic API contract schema drift.

      Dynamic schemas not allowlisted:
        #{unreviewed.empty? ? '(none)' : unreviewed.join("\n    ")}

      Stale dynamic allowlist entries:
        #{stale.empty? ? '(none)' : stale.join("\n    ")}
    MSG
  end

  test "nested flexible schemas are explicitly allowlisted" do
    flexible = ApiContracts.contracts.flat_map do |action, contract|
      entries = nested_flexible_schema_paths(contract.request, "#{action} request")
      contract.responses.each do |status, schema|
        entries.concat(nested_flexible_schema_paths(schema, "#{action} #{status} response"))
      end
      entries
    end.sort

    expected = active_allowlist(NESTED_FLEXIBLE_SCHEMA_ALLOWLIST)
    # An MCP or server API subclass inherits its parent's schema, so the parent's review covers it.
    inherited = flexible.select { |e| expected.include?(e.sub(/\AApi::V1::(Mcp|Server)::/, "Api::V1::")) }
    unreviewed = flexible - expected - inherited
    stale = expected - flexible

    assert unreviewed.empty? && stale.empty?, <<~MSG
      Nested flexible API contract schema drift.

      Flexible nested schemas not allowlisted:
        #{unreviewed.empty? ? '(none)' : unreviewed.join("\n    ")}

      Stale nested flexible allowlist entries:
        #{stale.empty? ? '(none)' : stale.join("\n    ")}
    MSG
  end

  private

  # Controller#action for every app API route (api/ + public/), matching the
  # "controller.class.name#action_name" key the runtime hook uses.
  #
  # The entire `api/v1/analytics/` namespace is intentionally governed by
  # AnalyticsSchemaContractTest (OUTPUT/INPUT schemas), NOT by ApiContracts, so
  # those endpoints are excluded here. The separate guard test below
  # ("every analytics endpoint has an INPUT_SCHEMA mapping") ensures the
  # analytics namespace cannot hide an untracked endpoint.
  # MCP analytics controllers subclass these and inherit their schemas, so they share the delegation.
  ANALYTICS_CONTROLLER_PREFIXES = %w[api/v1/analytics/ api/v1/mcp/analytics/].freeze

  def app_endpoints
    Rails.application.routes.routes.filter_map do |route|
      defaults = route.defaults
      controller = defaults[:controller]
      action = defaults[:action]
      next if controller.nil? || action.nil?
      next unless controller.start_with?("api/", "public/")
      next if controller.start_with?(*ANALYTICS_CONTROLLER_PREFIXES)

      klass = controller.split("/").map(&:camelize).join("::") + "Controller"
      "#{klass}##{action}"
    end.uniq
  end

  # Every live route in the analytics namespace must map to an INPUT_SCHEMAS
  # entry via AnalyticsSchemaContractTest::INPUT_SCHEMA_TO_ACTION. This is the
  # guard that prevents an analytics endpoint from escaping the schema-contract
  # system simply by being excluded from the api_contracts coverage gate above.
  def analytics_endpoints
    Rails.application.routes.routes.filter_map do |route|
      defaults = route.defaults
      controller = defaults[:controller]
      action = defaults[:action]
      next if controller.nil? || action.nil?
      next unless controller.start_with?(*ANALYTICS_CONTROLLER_PREFIXES)

      klass = (controller.split("/").map(&:camelize).join("::") + "Controller").constantize
      [klass, action.to_sym]
    end.uniq
  end

  def ee_only_endpoint_in_oss_mode?(endpoint)
    ENV.fetch("GROVS_EE", "false") != "true" && EE_ONLY_ENDPOINTS.include?(endpoint)
  end

  # Allowlist entries are "<Controller#action> <rest>"; EE-only ones have no contract to match in OSS mode.
  def active_allowlist(entries)
    entries.reject { |entry| ee_only_endpoint_in_oss_mode?(entry.split(" ").first) }
  end

  def broad_schema?(schema)
    [ApiContracts::ANY_OBJECT, ApiContracts::JSON_VALUE].include?(schema)
  end

  def raw_unchecked?(schema)
    schema == :any
  end

  def dynamic_schema?(schema)
    defined?(ApiContracts::DYNAMIC_OBJECT_RESPONSE) && [ApiContracts::DYNAMIC_OBJECT_RESPONSE, ApiContracts::DYNAMIC_ARRAY_RESPONSE].include?(schema)
  end

  def nested_flexible_schema_paths(schema, path, nested: false)
    return [] if raw_unchecked?(schema)
    return [path] if nested && broad_schema?(schema)
    return [] unless schema.is_a?(Hash)

    entries = []
    entries << "#{path}.additionalProperties" if nested && schema["additionalProperties"] == true

    schema.fetch("properties", {}).each do |name, property_schema|
      entries.concat(nested_flexible_schema_paths(property_schema, "#{path}.properties.#{name}", nested: true))
    end

    if schema["items"]
      entries.concat(nested_flexible_schema_paths(schema["items"], "#{path}.items", nested: true))
    end

    if schema["additionalProperties"].is_a?(Hash)
      entries.concat(nested_flexible_schema_paths(schema["additionalProperties"], "#{path}.additionalProperties", nested: true))
    end

    %w[oneOf anyOf allOf].each do |keyword|
      Array(schema[keyword]).each_with_index do |subschema, index|
        entries.concat(nested_flexible_schema_paths(subschema, "#{path}.#{keyword}[#{index}]", nested: true))
      end
    end
    entries
  end
end
