require "test_helper"
require_relative "../../../test/integration/mcp_auth_test_helper"
require_relative "../../../test/integration/auth_test_helper"

class McpSegmentsTest < ActionDispatch::IntegrationTest
  include McpAuthTestHelper
  include AuthTestHelper
  include AuditTestHelper
  include ClickhouseTestHelper

  fixtures :instances, :users, :instance_roles, :projects

  CHECKOUT = { version: 1, operator: "or", groups: [{ operator: "and", conditions: [
    { type: "event", event_name: "checkout", window: { last_days: 30 } }
  ] }] }.freeze

  setup do
    skip_unless_clickhouse!
    @__clickhouse_test_started = true
    @project = projects(:one)
    @headers = create_mcp_headers_for(users(:member_user))
    @base = "#{MCP_PREFIX}/projects/#{@project.hashid}/segments"
    insert_ch_events([ev(1, "RO"), ev(2, "RO"), ev(3, "DE")])
  end

  teardown do
    keys = %i[dashboard mcp].flat_map do |lane|
      cfg = Segments::Permits::LANES.fetch(lane)
      [cfg[:global_key], Segments::Permits.project_key(@project.id, lane: lane)]
    end
    REDIS.with do |c|
      c.del(*keys)
      c.keys("segments:result*").each { |k| c.del(k) }
    end
  end

  def ev(visitor, country)
    { project_id: @project.id, visitor_id: visitor, device_id: visitor, event_type: "custom", event_name: "checkout",
      country: country, platform: "ios", created_at: (Time.now.utc - 2.days).strftime("%Y-%m-%d %H:%M:%S.000") }
  end

  def ch_on(&) = Clickhouse.stub(:read_enabled?, true) { Clickhouse.stub(:enabled?, true, &) }

  def fill_mcp_lane
    key = Segments::Permits.project_key(@project.id, lane: :mcp)
    REDIS.with { |c| c.zadd(key, Time.now.to_f + 60, "held") }
  end

  test "estimate, create and breakdown run on live ClickHouse" do
    ch_on do
      post "#{@base}/estimate", params: { definition: CHECKOUT }, headers: @headers, as: :json
      assert_response :ok
      assert_equal 3, json_response["persons"]

      post @base, params: { name: "Buyers", definition: CHECKOUT }, headers: @headers, as: :json
      assert_response :created
      id = json_response["segment"]["id"]

      post "#{@base}/#{id}/breakdown", params: { by: "country" }, headers: @headers, as: :json
      assert_response :ok
      assert_equal({ "RO" => 2, "DE" => 1 }, json_response["buckets"].to_h { |b| [b["value"], b["persons"]] })

      post "#{@base}/list", headers: @headers, as: :json
      assert_response :ok
      assert_equal ["Buyers"], json_response["segments"].map { |s| s["name"] }
    end
  end

  test "a saturated MCP lane refuses MCP work but leaves the dashboard lane alone" do
    ch_on do
      post @base, params: { name: "Buyers", definition: CHECKOUT }, headers: @headers, as: :json
      id = json_response["segment"]["id"]
      post "#{@base}/#{id}/breakdown", params: { by: "country" }, headers: @headers, as: :json
      assert_response :ok, "materializes the result while the lane is free"

      fill_mcp_lane
      post "#{@base}/#{id}/breakdown", params: { by: "platform" }, headers: @headers, as: :json
      assert_response :too_many_requests, "the breakdown query itself takes an MCP permit"
      assert_equal "segment_busy", json_response["error_code"]

      post "#{@base}/estimate", params: { definition: CHECKOUT.merge(groups: [{ operator: "and", conditions: [
        { type: "event", event_name: "checkout", window: { last_days: 7 } }
      ] }]) }, headers: @headers, as: :json
      assert_response :too_many_requests

      post "#{API_PREFIX}/projects/#{@project.id}/segments/estimate", params: { definition: CHECKOUT.merge(groups: [{ operator: "and", conditions: [
        { type: "event", event_name: "checkout", window: { last_days: 14 } }
      ] }]) }, headers: doorkeeper_headers_for(users(:member_user)), as: :json
      assert_response :ok
    end
  end

  test "invalid definitions and identity breakdowns are refused" do
    ch_on do
      post "#{@base}/estimate", params: { definition: { version: 1, operator: "or", groups: [] } }, headers: @headers, as: :json
      assert_response :unprocessable_entity

      post @base, params: { name: "Bad", definition: "nope" }, headers: @headers, as: :json
      assert_response :unprocessable_entity

      post @base, params: { name: "Buyers", definition: CHECKOUT }, headers: @headers, as: :json
      id = json_response["segment"]["id"]
      %w[properties.email properties.customer_id].each do |by|
        post "#{@base}/#{id}/breakdown", params: { by: by }, headers: @headers, as: :json
        assert_response :bad_request, by
        assert_equal "field_not_allowed", json_response["error_code"]
      end
    end
  end

  test "creating a segment is audited as the MCP token" do
    entitle!(@project.instance)
    ch_on { post @base, params: { name: "Audited", definition: CHECKOUT }, headers: @headers, as: :json }
    assert_response :created
    event = AuditEvent.where(action: "segment.created").last
    assert_equal "mcp_token", event.actor["via"]
  end
end
