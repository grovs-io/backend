require "test_helper"
require_relative "auth_test_helper"

class SdkStatusApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include ClickhouseTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs, :links,
           :devices, :visitors, :events, :purchase_events

  setup do
    @project = projects(:one)
    @empty = projects(:one_test)
    @headers = doorkeeper_headers_for(users(:member_user))
  end

  test "requires a token" do
    get status_path(@project), headers: api_headers

    assert_response :unauthorized
  end

  test "a project of another instance is forbidden" do
    get status_path(projects(:two)), headers: @headers

    assert_response :forbidden
  end

  test "reports latest SDK device stamp per platform, the web stamp and all-time data flags" do
    ios_at = 3.days.ago.change(usec: 0)
    android_at = 5.days.ago.change(usec: 0)
    Visitor.create!(project: @project, device: new_device("ios"), web_visitor: true)
    Visitor.create!(project: projects(:two), device: devices(:android_device))
    stamp(devices(:ios_device), ios_at)
    stamp(devices(:android_device), android_at)
    web_at = 2.hours.ago.change(usec: 0)
    Project.where(id: @project.id).update_all(web_sdk_last_seen_at: web_at)

    body = fetch_status(@project)

    assert_equal ios_at.iso8601, body["ios_seen_at"]
    assert_equal android_at.iso8601, body["android_seen_at"]
    assert_equal web_at.iso8601, body["web_seen_at"]
    assert_equal true, body["has_events"]
    assert_equal true, body["has_purchases"]
    assert_equal true, body["has_links"]
  end

  test "an empty project reports nulls and false, ignoring other projects' data" do
    Visitor.create!(project: projects(:two), device: devices(:ios_device), created_at: 1.minute.ago)
    Project.where(id: projects(:two).id).update_all(web_sdk_last_seen_at: Time.current)

    body = fetch_status(@empty)

    assert_equal({ "ios_seen_at" => nil, "android_seen_at" => nil, "web_seen_at" => nil,
                   "has_events" => false, "has_purchases" => false, "has_links" => false }, body)
  end

  test "has_purchases counts revenue rollups when no raw purchase rows exist" do
    DailyProjectMetric.create!(project_id: @empty.id, event_date: Date.current, platform: "ios", revenue: 0, units_sold: 0)
    assert_equal false, fetch_status(@empty)["has_purchases"]

    DailyProjectMetric.create!(project_id: @empty.id, event_date: Date.yesterday, platform: "ios", revenue: 3895, units_sold: 8)
    assert_equal true, fetch_status(@empty)["has_purchases"]
  end

  test "an iOS-only project reports android as unseen and ignores stamps past the lookback" do
    stamp(devices(:android_device), 31.days.ago)
    stamp(devices(:ios_device), 1.day.ago)

    body = fetch_status(@project)

    assert_nil body["android_seen_at"]
    assert_not_nil body["ios_seen_at"]
  end

  test "an old visitor with a fresh device stamp still counts as seen" do
    visitors(:ios_visitor).update_columns(created_at: 31.days.ago)
    seen_at = 1.hour.ago.change(usec: 0)
    stamp(devices(:ios_device), seen_at)

    assert_equal seen_at.iso8601, fetch_status(@project)["ios_seen_at"]
  end

  test "a device stamp older than the lookback reports nil" do
    stamp(devices(:ios_device), 31.days.ago)

    assert_nil fetch_status(@project)["ios_seen_at"]
  end

  test "a ClickHouse failure reports has_events true" do
    Clickhouse.stub(:read_enabled?, true) do
      Clickhouse.stub(:with, ->(*) { raise "boom" }) { assert_equal true, fetch_status(@empty)["has_events"] }
    end
  end

  test "link-redirect web visitors do not count as mobile SDK traffic" do
    Visitor.create!(project: @empty, device: devices(:ios_device), web_visitor: true)
    stamp(devices(:ios_device), 1.minute.ago, project: @empty)

    assert_nil fetch_status(@empty)["ios_seen_at"]
  end

  test "has_events falls through to ClickHouse when Postgres holds no events" do
    skip_unless_clickhouse!
    insert_ch_events([{ event_id: "sdk_status_e1", project_id: @empty.id, event_type: Grovs::Events::APP_OPEN,
                        visitor_id: 1, created_at: Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.000") }])

    Clickhouse.stub(:read_enabled?, true) { assert_equal true, fetch_status(@empty)["has_events"] }
    Clickhouse.stub(:read_enabled?, false) { assert_equal false, fetch_status(@empty)["has_events"] }
  end

  private

  def status_path(project)
    "#{API_PREFIX}/projects/#{project.id}/sdk_status"
  end

  def stamp(device, at, project: @project)
    DeviceLastSeen.upsert({ project_id: project.id, device_id: device.id, last_seen_at: at },
                          unique_by: %i[project_id device_id])
  end

  def new_device(platform)
    Device.create!(platform: platform, user_agent: "TestApp/1.0", ip: "10.0.0.9", remote_ip: "10.0.0.9")
  end

  def fetch_status(project)
    get status_path(project), headers: @headers
    assert_response :ok
    JSON.parse(response.body)
  end
end
