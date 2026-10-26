require "test_helper"

class Journeys::SplitConditionsTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include JourneyFixtures
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    @ana = visitors(:ios_visitor)
    @bo = visitors(:android_visitor)
    @journey = journey(@project)
  end

  teardown { REDIS.with { |c| c.keys("segments:permits:journeys:*").each { |k| c.del(k) } } }

  def ids = [@ana.id, @bo.id]
  def split(condition) = { "id" => "s", "type" => "split", "mode" => "condition", "condition" => condition.deep_stringify_keys }
  def decide(condition, forks = Journeys::Forks.new(@journey)) = forks.decide(split(condition), ids)
  def taken(for_ana, for_bo) = { @ana.id => for_ana, @bo.id => for_bo }

  def event(name, visitor, type: "custom", **properties)
    { project_id: @project.id, event_type: type, event_name: name, visitor_id: visitor.id, platform: "ios",
      created_at: 1.hour.ago.utc.strftime("%Y-%m-%d %H:%M:%S.%L"), properties: properties }
  end

  def on_event(operator, field, value = nil)
    { kind: "event", days: 7, min_count: 1, event: { name: "purchase", filters: [{ field: field, op: operator, value: value }] } }
  end

  test "every filter operator in the split's ClickHouse query agrees with the matcher a device uses" do
    skip_unless_clickhouse!
    props = { @ana.id => { "amount" => 30, "plan" => "Gold", "coupon" => "SPRING" }, @bo.id => { "amount" => 5, "plan" => "Silver" } }
    insert_ch_events([event("purchase", @ana, **props[@ana.id].symbolize_keys), event("purchase", @bo, **props[@bo.id].symbolize_keys)])
    cases = [["is_set", "coupon", nil], ["is_not_set", "coupon", nil], ["between", "amount", [10, 50]], ["between", "amount", ["1", "5"]],
             ["gt", "amount", 10], ["lt", "amount", 10], ["eq", "plan", "gold"], ["neq", "plan", "GOLD"],
             ["contains", "plan", "ILV"], ["not_contains", "plan", "ilv"]]
    expected = [%w[yes_next no_next], %w[no_next yes_next], %w[yes_next no_next], %w[no_next yes_next], %w[yes_next no_next],
                %w[no_next yes_next], %w[yes_next no_next], %w[no_next yes_next], %w[no_next yes_next], %w[yes_next no_next]]
    cases.zip(expected).each do |(op, field, value), (ana, bo)|
      assert_equal taken(ana, bo), decide(on_event(op, field, value)), "#{op} #{field} #{value.inspect}"
      matcher = ids.index_with { |id| Journeys::Matcher.compare(props[id][field], op, value) ? "yes_next" : "no_next" }
      assert_equal taken(ana, bo), matcher, "matcher #{op}"
    end
  end

  test "a screen split matches the screen name in any case, and only screen views" do
    skip_unless_clickhouse!
    insert_ch_events([event("", @ana, type: "screen_view").merge(screen_name: "Checkout"), event("checkout", @bo)])
    assert_equal taken("yes_next", "no_next"), decide(kind: "event", days: 7, min_count: 1, event: { screen: "checkout" })
  end

  test "a filter on a field that is not a plain name is refused before any query is built" do
    Clickhouse.stub(:with, ->(*) { flunk "no query for a bad field" }) do
      error = assert_raises(ArgumentError) { decide(on_event("eq", "a`) OR 1=1 --", "x")) }
      assert_equal "bad field", error.message
    end
  end

  test "an outage defers the split; a broken query surfaces as itself" do
    timeout = ClickHouse::Client::DatabaseError.new("Code: 159. DB::Exception: Timeout exceeded: TIMEOUT_EXCEEDED")
    Clickhouse.stub(:with, ->(*) { raise timeout }) do
      assert_raises(Clickhouse::Unavailable) { decide(on_event("eq", "plan", "gold")) }
    end
    broken = ClickHouse::Client::DatabaseError.new("Code: 47. DB::Exception: Unknown identifier: plan")
    Clickhouse.stub(:with, ->(*) { raise broken }) do
      assert_same broken, assert_raises(ClickHouse::Client::DatabaseError) { decide(on_event("eq", "plan", "gold")) }
    end
    Clickhouse.stub(:with, ->(*) { raise Errno::ECONNREFUSED }) do
      assert_raises(Clickhouse::Unavailable) { decide(on_event("eq", "plan", "gold")) }
    end
  end

  test "exists and not_exists read the profile, an empty value is not set, and a write earlier in the pass counts" do
    @ana.update_columns(sdk_attributes: { "plan" => "premium" })
    @bo.update_columns(sdk_attributes: { "plan" => "" })
    assert_equal taken("yes_next", "no_next"), decide(kind: "attribute", key: "plan", op: "exists")
    assert_equal taken("no_next", "yes_next"), decide(kind: "attribute", key: "plan", op: "not_exists")

    written = Journeys::Forks.new(@journey, { @bo.id => { "plan" => "trial" }, @ana.id => { "plan" => nil } })
    assert_equal taken("no_next", "yes_next"), decide({ kind: "attribute", key: "plan", op: "exists" }, written)
  end

  test "a condition of an unknown kind sends everyone down no, never failing the batch" do
    assert_equal taken("no_next", "no_next"), decide(kind: "weather", values: ["sunny"])
  end
end
