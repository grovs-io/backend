require "test_helper"
require "sidekiq/testing"

class Journeys::ObserveTest < ActiveSupport::TestCase
  include JourneyFixtures
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    @ana = visitors(:ios_visitor)
    Sidekiq::Testing.fake!
    JourneyEventJob.clear
    REDIS.with { |conn| conn.del(Journeys::Watchlist.key(@project.id)) }
  end

  teardown { Sidekiq::Testing.disable! }

  def row(name, data: {}, event: Grovs::Events::CUSTOM, device: @ana.device_id)
    { project_id: @project.id, device_id: device, event: event, event_name: name, data: data, created_at: Time.current }
  end

  def index = { [@project.id, @ana.device_id] => @ana }

  def queries(&block)
    sql = []
    ActiveSupport::Notifications.subscribed(->(*, payload) { sql << payload[:sql] unless payload[:name] == "SCHEMA" }, "sql.active_record", &block)
    sql
  end

  test "a project without journeys costs one cache read and no query" do
    JourneyGateway.observe([row("add_to_cart")], index)
    assert_empty queries { JourneyGateway.observe([row("add_to_cart"), row("checkout")], index) }
    assert_empty JourneyEventJob.jobs
  end

  test "only watched events are sent on, with only the properties a filter reads" do
    filters = [{ "field" => "value", "op" => "gt", "value" => 20 }]
    j = live_journey(@project, entry: ADD_TO_CART.merge("event" => { "name" => "add_to_cart", "filters" => filters }),
                               goals: [{ "screen" => "Checkout", "window_hours" => 168 }])
    screen = row("screen_view", event: Grovs::Events::SCREEN_VIEW, data: { "screen_name" => "checkout" })
    assert_empty(queries { JourneyGateway.observe([row("add_to_cart", data: { "value" => 30, "secret" => "x" }), row("other"), screen], index) })

    payload = JourneyEventJob.jobs.sole["args"]
    assert_equal @project.id, payload[0]
    assert_equal [[@ana.id, "i:#{@ana.sdk_identifier}", "add_to_cart", nil, { "value" => 30 }],
                  [@ana.id, "i:#{@ana.sdk_identifier}", "screen_view", "checkout", {}]], payload[1].map { |r| r.first(5) }
    assert_equal 2, payload.size, "rows, never a third argument an older worker would refuse"
    payload[1].each { |r| assert_in_delta Time.current.to_f * 1000, r[6], 5_000, "each row carries the server's receive time" }
    assert j.persisted?
  end

  test "a change to a journey refreshes the list; server events and unknown devices are ignored" do
    JourneyGateway.observe([row("add_to_cart")], index)
    live_journey(@project)
    JourneyGateway.observe([row("add_to_cart"), row("journey_entered"), row("add_to_cart", device: devices(:web_device).id)], index)
    assert_equal 1, JourneyEventJob.jobs.sole["args"][1].size
  end

  test "system events are watched under their type" do
    live_journey(@project, entry: ADD_TO_CART.merge("event" => { "system" => "install" }))
    JourneyGateway.observe([row("", event: Grovs::Events::INSTALL), row("", event: Grovs::Events::APP_OPEN)], index)
    assert_equal [[@ana.id, "i:#{@ana.sdk_identifier}", "install", nil, {}]], JourneyEventJob.jobs.sole["args"][1].map { |r| r.first(5) }
  end

  test "a failure never reaches the batch" do
    live_journey(@project)
    Journeys.stub(:observe, ->(*) { raise "boom" }) { assert_nothing_raised { JourneyGateway.observe([row("add_to_cart")], index) } }
  end
end
