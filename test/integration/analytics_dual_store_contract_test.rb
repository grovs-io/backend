require "test_helper"
require_relative "auth_test_helper"

class AnalyticsDualStoreContractTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include ClickhouseTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :links, :devices, :visitors

  DAY = Date.current.to_s.freeze
  START = "2026-04-01".freeze

  setup do
    @project = projects(:one)
    # The one the default search params (active, non-SDK) actually return.
    @link = links(:no_custom_redirect_link)
    @visitor = visitors(:ios_visitor)
    @headers = doorkeeper_headers_for(users(:admin_user))

    @original_read = Rails.application.config.clickhouse_read_enabled
    @original_rollups = Rails.application.config.clickhouse_analytics_rollups_read_enabled
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = @original_rollups
  end

  ENDPOINTS = {
    "visitors/search" => {
      ch_proof: ->(json) { json["visitors"].sum { |v| v["total_views"].to_i } },
      pg_value: 0, ch_value: 3
    },
    "visitors/aggregated" => {
      ch_proof: ->(json) { json["visitors"].sum { |v| v["invited_views"].to_i } },
      pg_value: 0, ch_value: 3
    },
    "events/sorted" => {
      ch_proof: ->(json) { json["result"].sum { |r| r.dig("metrics", "view").to_i } },
      pg_value: 0, ch_value: 3
    },
    "dashboard/metrics_overview" => {
      ch_proof: ->(json) { json.dig("metrics", "current", "views").to_i },
      pg_value: 0, ch_value: 3
    }
  }.freeze

  ENDPOINTS.each do |path, spec|
    test "#{path} satisfies its contract on the Postgres path" do
      flags(rollups: false)
      call(path)

      assert_response :success
      assert_equal spec[:pg_value], spec[:ch_proof].call(JSON.parse(response.body)),
                   "Postgres has no stats for #{DAY}"
    end

    test "#{path} satisfies its contract on the ClickHouse path" do
      skip_unless_clickhouse!
      truncate_clickhouse_tables
      flags(rollups: true)
      seed_clickhouse
      call(path)

      assert_response :success
      assert_equal spec[:ch_value], spec[:ch_proof].call(JSON.parse(response.body)),
                   "value only ClickHouse can produce — otherwise this silently tested PG twice"
    end
  end

  test "visitor_details satisfies its contract on the Postgres path" do
    flags(rollups: false)
    get_details

    assert_response :success
  end

  test "visitor_details satisfies its contract on the ClickHouse path" do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    flags(rollups: true)
    seed_clickhouse
    get_details

    assert_response :success
    assert_equal 3, JSON.parse(response.body).dig("metrics", "total_views").to_i,
                 "value only ClickHouse can produce"
  end

  private

  def flags(rollups:)
    Rails.application.config.clickhouse_read_enabled = rollups
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = rollups
  end

  def call(path)
    post("#{API_PREFIX}/projects/#{@project.id}/#{path}",
                params: { active: "true", sdk: "false", page: 1, per_page: 20,
                          event_type: "view", sort_by: "views",
                          start_date: START, end_date: DAY },
                headers: @headers)
  end

  def get_details
    get "#{API_PREFIX}/projects/#{@project.id}/visitors/#{@visitor.id}", headers: @headers
  end

  # Real rows so flag-on responses aren't trivially empty.
  def seed_clickhouse
    Clickhouse.with do |conn|
      # inviter_id set so the invited-visitor grain has a population too.
      conn.insert("visitor_metrics_daily", [{
        project_id: @project.id, visitor_id: @visitor.id, event_date: DAY, platform: "ios",
        views: 3, opens: 1, installs: 1, reinstalls: 0, time_spent: 5,
        reactivations: 0, app_opens: 2, user_referred: 0, inviter_id: visitors(:android_visitor).id
      }])
      conn.insert("link_metrics_daily", [{
        project_id: @project.id, link_id: @link.id, event_date: DAY, platform: "ios",
        views: 3, opens: 1, installs: 1, reinstalls: 0, time_spent: 5,
        reactivations: 0, app_opens: 2, user_referred: 0
      }])
      conn.insert("link_daily", [{
        project_id: @project.id, link_id: @link.id, campaign_id: 0, event_date: DAY,
        event_type: "view", platform: "ios", cnt: 3, total_engagement_time: 5
      }])
      conn.insert("link_session_daily", [{
        project_id: @project.id, link_id: @link.id, event_date: DAY, platform: "ios",
        sessions: 2, duration_ms_sum: 60_000,
        engaged_sessions: 2, engaged_duration_ms_sum: 60_000
      }])
      conn.insert("project_metrics_daily", [{
        project_id: @project.id, event_date: DAY, platform: "ios",
        views: 3, opens: 1, installs: 1, reinstalls: 0, app_opens: 2,
        unique_visitors: 1, unique_devices: 1
      }])
    end
  end
end
