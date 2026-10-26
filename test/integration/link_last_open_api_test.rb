require "test_helper"
require_relative "auth_test_helper"

class LinkLastOpenApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include ClickhouseTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs, :links,
           :devices, :visitors

  setup do
    @project = projects(:one)
    @link = links(:basic_link)
    @headers = doorkeeper_headers_for(users(:member_user))
  end

  test "requires a token" do
    get open_path(@project, @link), headers: api_headers

    assert_response :unauthorized
  end

  test "a link of another project is forbidden" do
    get open_path(projects(:one_test), @link), headers: @headers

    assert_response :forbidden
  end

  test "an unknown link is not found" do
    get open_path(@project, Link.new(id: 0)), headers: @headers

    assert_response :not_found
  end

  test "a link nobody opened reports null" do
    assert_nil fetch_open(@link)
  end

  test "the app's last-visit row reports the device right away" do
    at = 2.minutes.ago.change(usec: 0)
    VisitorLastVisit.create!(project: @project, visitor: visitors(:ios_visitor), link: @link, updated_at: at)

    assert_equal({ "opened_at" => at.iso8601, "platform" => "ios", "model" => "iPhone 15 Pro",
                   "app_version" => "1.5.0" }, fetch_open(@link))
  end

  test "a browser visit of the link does not count as an app open" do
    web = Visitor.create!(project: @project, device: devices(:ios_device), web_visitor: true)
    VisitorLastVisit.create!(project: @project, visitor: web, link: @link)

    assert_nil fetch_open(@link)
  end

  test "falls back to the latest open event once the last visit moved to another link" do
    at = 1.hour.ago.change(usec: 0)
    Event.create!(event: Grovs::Events::VIEW, project: @project, device: devices(:ios_device), link: @link)
    Event.create!(event: Grovs::Events::OPEN, project: @project, device: devices(:android_device), link: @link,
                  created_at: at)

    open = fetch_open(@link)

    assert_equal at.iso8601, open["opened_at"]
    assert_equal "android", open["platform"]
  end

  test "a newer open event by another device beats an older last-visit row" do
    VisitorLastVisit.create!(project: @project, visitor: visitors(:ios_visitor), link: @link, updated_at: 2.hours.ago)
    at = 10.minutes.ago.change(usec: 0)
    Event.create!(event: Grovs::Events::OPEN, project: @project, device: devices(:android_device), link: @link,
                  created_at: at)

    open = fetch_open(@link)

    assert_equal at.iso8601, open["opened_at"]
    assert_equal "android", open["platform"]
  end

  test "reads ClickHouse when Postgres holds no events" do
    skip_unless_clickhouse!
    at = Time.current.utc.change(usec: 0)
    insert_ch_events([{ event_id: "last_open_e1", project_id: @project.id, event_type: Grovs::Events::INSTALL,
                        visitor_id: 1, device_id: devices(:ios_device).id, link_id: @link.id,
                        created_at: at.strftime("%Y-%m-%d %H:%M:%S.000") }])

    Clickhouse.stub(:read_enabled?, true) { assert_equal at.iso8601, fetch_open(@link)["opened_at"] }
    Clickhouse.stub(:read_enabled?, false) { assert_nil fetch_open(@link) }
  end

  private

  def open_path(project, link)
    "#{API_PREFIX}/projects/#{project.id}/links/#{link.id}/last_open"
  end

  def fetch_open(link)
    get open_path(@project, link), headers: @headers
    assert_response :ok
    JSON.parse(response.body)["open"]
  end
end
