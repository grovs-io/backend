# frozen_string_literal: true

require "test_helper"
require_relative "../mcp_auth_test_helper"
require_relative "../auth_test_helper"
require_relative "../analytics_schema_helper"

class McpProjectAnalyticsTest < ActionDispatch::IntegrationTest
  include McpAuthTestHelper
  include AuthTestHelper
  include AnalyticsSchemaHelper
  include ClickhouseTestHelper

  fixtures :instances, :users, :instance_roles, :projects

  setup do
    @user = users(:admin_user)
    @project = projects(:one)
    @headers = create_mcp_headers_for(@user)
    @base = "#{MCP_PREFIX}/projects/#{@project.hashid}/analytics"
  end

  teardown { Rails.cache.clear }

  def ch_on(&)
    Clickhouse.stub(:read_enabled?, true, &)
  end

  def ev(id, event_type, days_ago, extra = {})
    { event_id: "mcp_an_#{id}", project_id: @project.id, event_type: event_type, link_id: 0,
      visitor_id: 700 + id, device_id: 700 + id, platform: "ios",
      created_at: ((Date.current - days_ago).to_time(:utc) + 12.hours).strftime("%Y-%m-%d %H:%M:%S.%3N") }.merge(extra)
  end

  test "query runs the dashboard query on live ClickHouse with the project hashid" do
    skip_unless_clickhouse!
    @ch_auto_rebuild_breakdowns = true
    insert_ch_events([ev(1, Grovs::Events::INSTALL, 1, country: "RO"), ev(2, Grovs::Events::INSTALL, 2, country: "RO"),
                      ev(3, Grovs::Events::INSTALL, 2, country: "DE"), ev(4, Grovs::Events::INSTALL, 20, country: "RO")])
    ch_on do
      post "#{@base}/query", params: { metric: "installs", group_by: "country", compare: true,
                                       start_date: (Date.current - 13).to_s, end_date: Date.current.to_s }, headers: @headers, as: :json
    end
    assert_response :ok
    assert_analytics_schema(:metric_query)
    body = json_response
    assert_equal [["RO", 2, 1], ["DE", 1, 0]], body["rows"].map { |r| [r["key"], r["value"], r["previous"]] }
    assert_equal({ "start" => (Date.current - 27).to_s, "end" => (Date.current - 14).to_s }, body["previous_range"])
  end

  test "previous_range shows the window clamped to the retention cutoff" do
    cutoff = ::Analytics::RetentionPolicy.for(@project.instance).queryable_cutoff_date
    ::Analytics::MetricQueryService.stub(:compute, ->(_pid, q) { { rows: [], previous_range: { start: q.prev_start_day, end: q.prev_end_day } } }) do
      ch_on do
        post "#{@base}/query", params: { metric: "installs", compare: true, start_date: (cutoff + 2).to_s,
                                         end_date: (cutoff + 11).to_s }, headers: @headers, as: :json
      end
    end
    assert_response :ok
    assert_equal cutoff.to_s, json_response["previous_range"]["start"]
  end

  test "parent checks fire through the MCP route" do
    ch_on do
      post "#{@base}/query", params: { metric: "unique_visitors", group_by: "city", start_date: (Date.current - 120).to_s,
                                       end_date: Date.current.to_s }, headers: @headers, as: :json
      assert_response :unprocessable_entity
      assert_equal "query_too_heavy", json_response["error_code"]

      post "#{@base}/query", params: { metric: "nope" }, headers: @headers, as: :json
      assert_response :bad_request

      cutoff = ::Analytics::RetentionPolicy.for(@project.instance).queryable_cutoff_date
      post "#{@base}/query", params: { metric: "installs", start_date: (cutoff - 5).to_s, end_date: (cutoff + 5).to_s },
                             headers: @headers, as: :json
      assert_response :unprocessable_entity
      assert_equal "retention_window_exceeded", json_response["error_code"]
    end
  end

  test "identity group_by is refused; plain properties pass" do
    ch_on do
      %w[user.tier properties.email properties.customer_id properties.customerEmail properties.userId properties.user.email
         properties.session_id properties.anonymous_id properties.sdk_identifier].each do |g|
        post "#{@base}/query", params: { metric: "installs", group_by: g }, headers: @headers, as: :json
        assert_response :bad_request, g
        assert_equal "field_not_allowed", json_response["error_code"], g
      end
      ::Analytics::MetricQueryService.stub(:run, { rows: [] }) do
        %w[properties.plan properties.product_id properties.order_id campaign_id link_id].each do |g|
          post "#{@base}/query", params: { metric: "installs", group_by: g }, headers: @headers, as: :json
          assert_response :ok, g
        end
      end
    end
  end

  test "field values refuse identifiers and identity-looking properties" do
    ch_on do
      %w[visitor visitor_id sdk_identifier session_id user.email email customer_id phoneNumber].each do |f|
        post "#{@base}/events/field-values", params: { field: f }, headers: @headers, as: :json
        assert_response :bad_request, f
        assert_equal "field_not_allowed", json_response["error_code"], f
      end
      ::Analytics::EventsQueryService.stub(:field_values, { values: [{ value: "signup" }] }) do
        %w[event_name campaign_id plan product_id].each do |f|
          post "#{@base}/events/field-values", params: { field: f }, headers: @headers, as: :json
          assert_response :ok, f
        end
      end
      post "#{@base}/events/field-values", params: { field: "bad`key" }, headers: @headers, as: :json
      assert_response :bad_request
      assert_nil json_response["error_code"], "the parent's own check still answers unknown fields"
    end
  end

  test "key metrics, retention, events and fields reach their services" do
    ch_on do
      ::Analytics::OverviewStatsService.stub(:key_metrics, { metrics: { installs: 3 }, unsupported_metrics: [] }) do
        post "#{@base}/key-metrics", headers: @headers, as: :json
      end
      assert_response :ok
      assert_equal 3, json_response["metrics"]["installs"]

      ::Analytics::RetentionService.stub(:summary, { cohorts: [] }) do
        post "#{@base}/retention", params: { granularity: "monthly" }, headers: @headers, as: :json
      end
      assert_response :ok

      ::Analytics::VisitorUuidResolver.stub(:resolve_many, {}) do
        ::Analytics::EventsQueryService.stub(:list, { data: [], next_cursor: nil, total_count: 0 }) do
          post "#{@base}/events", params: { limit: 10 }, headers: @headers, as: :json
        end
      end
      assert_response :ok

      ::Analytics::EventsQueryService.stub(:fields, { fields: [{ name: "plan", type: "property" }] }) do
        post "#{@base}/events/fields", headers: @headers, as: :json
      end
      assert_response :ok
      assert_equal "plan", json_response["fields"].first["name"]
    end
  end

  test "segment filters are refused so MCP never fills the dashboard segment lane" do
    ch_on do
      %w[events retention key-metrics].each do |path|
        post "#{@base}/#{path}", params: { segment_id: "abc" }, headers: @headers, as: :json
        assert_response :bad_request, path
        assert_equal "unsupported_filter", json_response["error_code"], path
      end
    end
  end

  test "identity-like names are caught in any casing, flags and business ids pass" do
    blocked = %w[session_id anonymous_id sdk_identifier adid customerEmail phoneNumber mobile_number client_ip ip_addr fullName]
    allowed = %w[product_id order_id ad_id adId mobile is_mobile has_email product_name tier zip]
    assert_empty blocked.reject { |k| McpIdentityPolicy.identity_property?(k) }
    assert_empty allowed.select { |k| McpIdentityPolicy.identity_property?(k) }
  end

  test "ClickHouse unavailable under primary is a 503 with its code, never zeros" do
    ch_on do
      ::Analytics::MetricQueryService.stub(:run, ->(*) { raise Clickhouse::Unavailable, "down" }) do
        post "#{@base}/query", params: { metric: "installs" }, headers: @headers, as: :json
      end
    end
    assert_response :service_unavailable
    assert_equal "clickhouse_unavailable", json_response["error_code"]
  end

  test "quota warning rides on the new routes" do
    @project.instance.update_column(:quota_exceeded, true)
    ch_on do
      ::Analytics::MetricQueryService.stub(:run, { rows: [] }) do
        post "#{@base}/query", params: { metric: "installs" }, headers: @headers, as: :json
      end
    end
    assert_response :ok
    assert_equal McpQuotaWarning::QUOTA_WARNING, json_response["_warning"]
  end

  test "auth: missing, revoked, foreign and dashboard tokens are refused" do
    ch_on do
      post "#{@base}/query", params: { metric: "installs" }, headers: mcp_host_headers, as: :json
      assert_response :unauthorized

      post "#{@base}/query", params: { metric: "installs" },
                             headers: doorkeeper_headers_for(@user).merge("Host" => MCP_HOST), as: :json
      assert_response :unauthorized

      outsider = create_mcp_headers_for(users(:oauth_user))
      post "#{@base}/query", params: { metric: "installs" }, headers: outsider, as: :json
      assert_response :forbidden

      McpToken.where(user: @user).update_all(revoked_at: Time.current)
      post "#{@base}/query", params: { metric: "installs" }, headers: @headers, as: :json
      assert_response :unauthorized
      assert_includes response.headers["WWW-Authenticate"], 'error="invalid_token"'
    end
  end

  test "numeric and malformed project ids do not resolve" do
    ch_on do
      post "#{MCP_PREFIX}/projects/#{@project.id}/analytics/query", params: { metric: "installs" }, headers: @headers, as: :json
      assert_response :not_found
      post "#{MCP_PREFIX}/projects/!!nope/analytics/query", params: { metric: "installs" }, headers: @headers, as: :json
      assert_response :not_found
    end
  end

  test "the MCP token does not open the dashboard route" do
    ch_on do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/query", params: { metric: "installs" },
                                                                    headers: @headers.merge(api_headers.slice("Host"))
    end
    assert_response :unauthorized
  end
end
