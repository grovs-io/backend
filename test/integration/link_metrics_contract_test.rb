require "test_helper"
require_relative "auth_test_helper"

# Runs the endpoint on BOTH stores so ApiContracts validates each path's response.
class LinkMetricsContractTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include ClickhouseTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :links, :devices

  DAY = "2026-05-01".freeze
  RANGE_START = "2020-01-01".freeze

  setup do
    @project = projects(:one)
    # RANGE_START predates any real retention window; this test is about metric parity.
    @project.instance.update!(cold_storage_days: 5000, delete_days: 5000)
    @link = links(:basic_link)
    @headers = doorkeeper_headers_for(users(:admin_user))
    Event.where(project: @project).delete_all

    @original_read = Rails.application.config.clickhouse_read_enabled
    @original_rollups = Rails.application.config.clickhouse_analytics_rollups_read_enabled
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = false
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = @original_rollups
  end

  test "postgres path reports custom and screen_view counts" do
    pg_event("view")
    3.times { pg_event(Grovs::Events::CUSTOM) }
    pg_event(Grovs::Events::SCREEN_VIEW)

    metrics = get_metrics

    assert_equal 1, metrics["view"]
    assert_equal 3, metrics["custom"]
    assert_equal 1, metrics["screen_view"]
  end

  # Deliberately different definitions — pinned so neither drifts unnoticed.
  test "avg_engagement_time is seconds-per-device on PG, seconds-per-session on CH" do
    pg_event(Grovs::Events::TIME_SPENT, engagement: 120)

    assert_equal 120.0, get_metrics["avg_engagement_time"]

    skip_unless_clickhouse!
    truncate_clickhouse_tables
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    seed_link_daily(Grovs::Events::TIME_SPENT => 1)
    seed_link_sessions(sessions: 2, duration_ms: 150_000)

    assert_equal 75.0, get_metrics["avg_engagement_time"], "average session length in seconds"
  end

  test "clickhouse path reports the same custom and screen_view counts" do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    seed_link_daily("view" => 1, Grovs::Events::CUSTOM => 3, Grovs::Events::SCREEN_VIEW => 1)

    metrics = get_metrics

    assert_equal 1, metrics["view"]
    assert_equal 3, metrics["custom"]
    assert_equal 1, metrics["screen_view"]
  end

  private

  def get_metrics
    post "#{API_PREFIX}/projects/#{@project.id}/events/search",
         params: { active: "true", sdk: "false", page: 1, start_date: RANGE_START, end_date: DAY },
         headers: @headers

    assert_response :success
    JSON.parse(response.body)["metrics"].fetch(@link.id.to_s)
  end

  def pg_event(event, engagement: 0)
    Event.create!(project: @project, device: devices(:ios_device), link: @link, event: event,
                  platform: "ios", engagement_time: engagement, created_at: "#{DAY} 10:00:00")
  end

  def seed_link_sessions(sessions:, duration_ms:)
    Clickhouse.with do |conn|
      conn.insert("link_session_daily", [{
        project_id: @project.id, link_id: @link.id, event_date: DAY, platform: "ios",
        sessions: sessions, duration_ms_sum: duration_ms,
        engaged_sessions: sessions, engaged_duration_ms_sum: duration_ms
      }])
    end
  end

  def seed_link_daily(counts)
    rows = counts.map do |event_type, cnt|
      { project_id: @project.id, link_id: @link.id, campaign_id: 0, event_date: DAY,
        event_type: event_type, platform: "ios", cnt: cnt, total_engagement_time: 0 }
    end
    Clickhouse.with { |conn| conn.insert("link_daily", rows) }
  end
end
