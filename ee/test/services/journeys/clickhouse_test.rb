require "test_helper"
require "sidekiq/testing"

class Journeys::ClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include JourneyFixtures
  include InAppFixtures
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    @ana = visitors(:ios_visitor)
    @bo = visitors(:android_visitor)
    [@ana, @bo].each { |v| v.update_columns(sdk_attributes: {}) }
    Sidekiq::Testing.fake!
    REDIS.with { |c| c.del(BatchEventProcessorJob::REDIS_KEY) }
  end

  teardown do
    Sidekiq::Testing.disable!
    REDIS.with { |c| c.del(BatchEventProcessorJob::REDIS_KEY, *c.keys("segments:permits:journeys:*")) }
  end

  def event(name, visitor:, at:, **properties)
    { project_id: @project.id, event_type: "custom", event_name: name, visitor_id: visitor.id, platform: "ios",
      created_at: at.utc.strftime("%Y-%m-%d %H:%M:%S.%L"), properties: properties }
  end

  def split_on_event(**condition)
    map(step("s", "split", mode: "condition", condition: { kind: "event", days: 7, min_count: 1 }.merge(condition), yes_next: "y", no_next: "n"),
        step("y", "set_attribute", key: "journey_path", value: "yes"), step("n", "set_attribute", key: "journey_path", value: "no"))
  end

  def paths = [@ana, @bo].map { |v| v.reload.sdk_attributes["journey_path"] }

  test "an event split asks ClickHouse once for the batch, with counts, window and filters" do
    skip_unless_clickhouse!
    insert_ch_events([event("viewed", visitor: @ana, at: 1.day.ago, sku: "A1"), event("viewed", visitor: @ana, at: 2.days.ago, sku: "B2"),
                      event("viewed", visitor: @bo, at: 10.days.ago, sku: "A1"), event("viewed", visitor: @bo, at: 1.hour.ago, sku: "B2")])
    live_journey(@project, steps: split_on_event(event: { name: "viewed", filters: [{ field: "sku", op: "contains", value: "a" }] }))
    signal(@project, seen(@ana, "add_to_cart"), seen(@bo, "add_to_cart"))
    assert_equal %w[yes no], paths

    live_journey(@project, steps: split_on_event(event: { name: "viewed" }, min_count: 2))
    [@ana, @bo].each { |v| v.update_columns(sdk_attributes: {}) }
    signal(@project, seen(@ana, "add_to_cart"), seen(@bo, "add_to_cart"))
    assert_equal %w[yes no], paths
  end

  test "a split on a system event reads its event type" do
    skip_unless_clickhouse!
    insert_ch_events([event("", visitor: @ana, at: 2.days.ago).merge(event_type: "app_open"), event("app_open", visitor: @bo, at: 1.day.ago)])
    live_journey(@project, steps: split_on_event(event: { system: "app_open" }))
    signal(@project, seen(@ana, "add_to_cart"), seen(@bo, "add_to_cart"))
    assert_equal %w[yes no], paths, "a custom event named like the type does not count"
  end

  test "with ClickHouse unavailable or its lane busy the batch stays due and nobody takes a branch" do
    j = live_journey(@project, steps: map(step("w", "wait", minutes: 5, next: "s"), *split_on_event(event: { name: "viewed" }).values))
    signal(@project, seen(@ana, "add_to_cart"))
    Clickhouse.stub(:with, ->(*) { raise Clickhouse::Unavailable, "down" }) do
      assert_equal :busy, step_all(j, at: 10.minutes.from_now)
    end
    row = row_of(j, @ana)
    assert_equal %w[active w], [row.state, row.step_id]
    assert_nil @ana.reload.sdk_attributes["journey_path"]

    Segments::Permits.stub(:with, ->(*, **) { raise Segments::Busy }) { assert_equal :busy, step_all(j, at: 10.minutes.from_now) }
    assert_equal "active", row_of(j, @ana).state
    assert_equal 0, counts(j).fetch(%w[w next], 0)
  end

  test "the report counts steps from journey_counts and reads the goal card with the journey's own events" do
    skip_unless_clickhouse!
    j = live_journey(@project, control_group: 50, goals: [{ "event" => "checkout", "window_hours" => 168 }],
                               steps: map(step("w", "wait", minutes: 5, until: { kind: "event", event: { name: "checkout" } }, timeout_next: nil)))
    day = Time.utc(2026, 9, 1, 12)
    rows = (1..120).flat_map do |id|
      grp = Experiments::Bucket.of(j.hashid, id) < 50 ? "journey_held" : "journey_entered"
      [event(grp, visitor: Struct.new(:id).new(id), at: day, campaign_id: j.hashid, scope: "campaign")] +
        (id.even? ? [event("checkout", visitor: Struct.new(:id).new(id), at: day + 1.hour)] : [])
    end
    insert_ch_events(rows)
    Journeys::Tally.add(j.id, { ["", "entered"] => 60, ["", "held"] => 60, %w[w reached] => 60, %w[w next] => 30 }, at: day)
    report = Journeys::Report.call(j, from: "2026-09-01", to: "2026-09-02")
    assert_equal [60, 60], report.values_at("entered", "held")
    assert_equal({ "reached" => 60, "now" => 0, "branches" => { "next" => 30, "timeout_next" => 0 } }, report["steps"]["w"])
    groups = report["goal"]["groups"].index_by { |g| g["id"] }
    assert_equal 120, groups["a"]["exposed"] + groups["control"]["exposed"]
    assert_equal 60, groups["a"]["converted"] + groups["control"]["converted"]
    assert_equal({}, report["paths"])
  end

  test "the report reads each percent split by the path people were recorded on, with conversions, revenue and confidence vs path A" do
    skip_unless_clickhouse!
    j = live_journey(@project, goals: [{ "purchase" => true, "window_hours" => 168 }],
                               steps: map(step("s", "split", mode: "percent", paths: [{ percent: 50, next: nil }, { percent: 50, next: nil }])))
    InAppSetting.create!(project: @project, control_group: 10)
    day = Time.utc(2026, 9, 1, 12)
    path = ->(id) { id.even? ? "path_0" : "path_1" }
    assert((1..240).any? { |id| path.call(id) != (Experiments::Bucket.of("#{j.hashid}:s", id) < 50 ? "path_0" : "path_1") }, "some differ from their bucket")
    buyers = (1..240).select { |id| path.call(id) == "path_0" ? (id % 20).zero? : id % 4 == 1 }
    recorded = ->(id, step_id, taken) { event("journey_path", visitor: Struct.new(:id).new(id), at: day, campaign_id: j.hashid, step_id: step_id, path: taken) }
    insert_ch_events((1..240).map { |id| recorded.call(id, "s", path.call(id)) } + [recorded.call(999, "other", "path_0")])
    Clickhouse.with do |conn|
      conn.insert("purchase_events", buyers.map do |id|
        at = (day + 1.hour).strftime("%Y-%m-%d %H:%M:%S")
        { project_id: @project.id, event_type: "buy", purchase_type: "one_time", product_id: "premium", usd_price_cents: 500, quantity: 1,
          transaction_id: "p#{id}", visitor_id: id, purchase_date: at, recorded_at: at, created_at: at }
      end)
    end

    card = Journeys::Report.call(j, from: "2026-09-01", to: "2026-09-02")["paths"]["s"]
    a, b = card["groups"].index_by { |g| g["id"] }.values_at("a", "b")
    assert_equal %w[a b], card["groups"].pluck("id")
    assert_equal [120, 12, 6_000, nil], a.values_at("exposed", "converted", "revenue_cents", "confidence")
    assert_equal [120, 60, 30_000], b.values_at("exposed", "converted", "revenue_cents")
    assert_operator b["confidence"], :>, 0.99
    assert_equal [0, 0], card.values_at("control_group", "project_control_group")
  end

  test "a person recorded on two paths of one split counts under their first" do
    skip_unless_clickhouse!
    j = live_journey(@project, steps: map(step("s", "split", mode: "percent", paths: [{ percent: 50, next: nil }, { percent: 50, next: nil }])))
    day = Time.utc(2026, 9, 1, 12)
    # Same day, and the later event sorts first by event_id, so an arbitrary pick lands on it.
    insert_ch_events([event("journey_path", visitor: @ana, at: day + 1.hour, campaign_id: j.hashid, step_id: "s", path: "path_0").merge(event_id: "a-later"),
                      event("journey_path", visitor: @ana, at: day, campaign_id: j.hashid, step_id: "s", path: "path_1").merge(event_id: "b-first")])
    groups = Experiments::Report.journey_path(j, "s", from: "2026-09-01", to: "2026-09-02")["groups"].index_by { |g| g["id"] }
    assert_equal [0, 1], [groups["a"]["exposed"], groups["b"]["exposed"]]
  end

  test "exposure carries the entry time, so a goal right after the triggering event converts on the goal card" do
    skip_unless_clickhouse!
    j = live_journey(@project, goals: [{ "event" => "checkout", "window_hours" => 168 }], steps: map(step("w", "wait")))
    ten = 30.minutes.ago.change(usec: 0)
    signal(@project, seen(@ana, "add_to_cart", at: ten), seen(@ana, "checkout", at: ten + 20.seconds))
    exposure = REDIS.with { |c| c.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1) }.map { |raw| JSON.parse(raw) }.find { |e| e["event_name"] == "journey_entered" }
    assert_equal ten, Time.iso8601(exposure["created_at"])
    insert_ch_events([event("journey_entered", visitor: @ana, at: Time.iso8601(exposure["created_at"]), campaign_id: j.hashid),
                      event("checkout", visitor: @ana, at: ten + 20.seconds)])
    groups = Journeys::Report.call(j, from: Date.current.iso8601, to: Date.current.iso8601)["goal"]["groups"].index_by { |g| g["id"] }
    assert_equal [1, 1], groups["a"].values_at("exposed", "converted")
  end

  test "the goal card counts any of the journey's goals, as the exit does, and a screen goal in any case" do
    skip_unless_clickhouse!
    goals = [{ "event" => "checkout", "window_hours" => 24 }, { "screen" => "Thank You", "window_hours" => 168 },
             { "purchase" => true, "products" => ["premium"], "window_hours" => 168 }]
    j = live_journey(@project, goals: goals, steps: map(step("w", "wait")))
    day = Time.utc(2026, 9, 1, 12)
    people = (1..4).map { |id| Struct.new(:id).new(id) }
    entered = people.map { |v| event("journey_entered", visitor: v, at: day, campaign_id: j.hashid) }
    screen = event("screen_view", visitor: people[1], at: day + 1.hour).merge(event_type: "screen_view", event_name: "", screen_name: "thank you")
    insert_ch_events(entered + [event("checkout", visitor: people[0], at: day + 1.hour), screen])
    Clickhouse.with do |conn|
      at = (day + 1.hour).strftime("%Y-%m-%d %H:%M:%S")
      conn.insert("purchase_events", [{ project_id: @project.id, event_type: "buy", purchase_type: "one_time", product_id: "premium", usd_price_cents: 500,
                                         quantity: 1, transaction_id: "g3", visitor_id: 3, purchase_date: at, recorded_at: at, created_at: at }])
    end
    a = Journeys::Report.call(j, from: "2026-09-01", to: "2026-09-02")["goal"]["groups"].find { |g| g["id"] == "a" }
    assert_equal [4, 3, 500], a.values_at("exposed", "converted", "revenue_cents")
  end

  test "a journey with a control group and no goal still gets the card, with revenue" do
    skip_unless_clickhouse!
    j = live_journey(@project, control_group: 50, steps: map(step("w", "wait")))
    day = Time.utc(2026, 9, 1, 12)
    entered = (1..200).find { |id| Experiments::Bucket.of(j.hashid, id) >= 50 }
    insert_ch_events([event("journey_entered", visitor: Struct.new(:id).new(entered), at: day, campaign_id: j.hashid)])
    Clickhouse.with do |conn|
      conn.insert("purchase_events", [{ project_id: @project.id, event_type: "buy", purchase_type: "one_time", product_id: "premium",
                                         usd_price_cents: 500, quantity: 1, transaction_id: "j1", visitor_id: entered,
                                         purchase_date: (day + 1.hour).strftime("%Y-%m-%d %H:%M:%S"),
                                         recorded_at: (day + 1.hour).strftime("%Y-%m-%d %H:%M:%S"),
                                         created_at: (day + 1.hour).strftime("%Y-%m-%d %H:%M:%S") }])
    end
    card = Journeys::Report.call(j, from: "2026-09-01", to: "2026-09-02")["goal"]
    assert_nil card["goal"]
    assert_equal 500, card["groups"].find { |g| g["id"] == "a" }["revenue_cents"]
  end
end
