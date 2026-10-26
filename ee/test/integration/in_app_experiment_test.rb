require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class InAppExperimentTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include ClickhouseTestHelper
  include InAppFixtures
  fixtures :instances, :users, :instance_roles, :projects, :visitors, :devices

  B = { "id" => "b", "content" => { "title" => "Hi", "message" => "Back again" } }.freeze
  DAY = Time.utc(2026, 9, 20, 10)

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
    entitle!(@project.instance)
    @member = doorkeeper_headers_for(users(:member_user))
    clear_in_app_stamps(@project)
    @campaign = live_in_app_campaign(@project, control_group: 20, variants: [B], conversion: { "event" => "checkout", "window_hours" => 24 })
  end

  def event(name, visitor:, at:, **properties)
    { project_id: @project.id, event_type: "custom", event_name: name, visitor_id: visitor, platform: "ios",
      created_at: at.utc.strftime("%Y-%m-%d %H:%M:%S.%L"), properties: properties }
  end

  def experiment(campaign = @campaign, **params)
    get "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{campaign.hashid}/experiment",
        params: { from: "2026-09-19", to: "2026-09-22" }.merge(params), headers: @member
    response.parsed_body["experiment"]
  end

  # Visitors whose bucket lands them in the group wanted, so the test does not depend on the hash.
  def people(group, count)
    (1..).lazy.select { |id| Experiments::Split.group(Experiments::Bucket.of(@campaign.hashid, id), control: 20, variants: 2) == group }.first(count)
  end

  def stamp(at) = at.utc.strftime("%Y-%m-%d %H:%M:%S.%L")

  def purchase(visitor:, at:, cents:, type: "buy", product: "premium", txn: SecureRandom.hex(6), written: at, **extra)
    { project_id: @project.id, event_type: type, purchase_type: "one_time", product_id: product, usd_price_cents: cents, quantity: 1,
      transaction_id: txn, visitor_id: visitor, purchase_date: stamp(at), recorded_at: stamp(at), created_at: stamp(written) }.merge(extra)
  end

  def insert_purchases(rows) = Clickhouse.with { |conn| conn.insert("purchase_events", rows) }

  test "revenue is net of refunds, counted once, inside the goal's window, per group and against the control" do
    a = people("a", 2)
    c = people("control", 2)
    mine = { campaign_id: @campaign.hashid }
    insert_ch_events([event("in_app_viewed", visitor: a[0], at: DAY, **mine), event("in_app_viewed", visitor: a[1], at: DAY, **mine),
                      event("in_app_held", visitor: c[0], at: DAY, **mine, scope: "campaign"),
                      event("in_app_held", visitor: c[1], at: DAY, **mine, scope: "campaign")])
    insert_purchases([purchase(visitor: a[0], at: DAY + 1.hour, cents: 1000, txn: "t1"),
                      purchase(visitor: a[0], at: DAY + 1.hour, cents: 1000, txn: "t1", written: DAY + 2.hours),
                      purchase(visitor: a[0], at: DAY + 2.hours, cents: 500, txn: "t2"),
                      purchase(visitor: a[0], at: DAY + 3.hours, cents: 500, txn: "t2", type: "refund"),
                      purchase(visitor: a[1], at: DAY + 25.hours, cents: 400),
                      purchase(visitor: a[1], at: DAY - 1.hour, cents: 300),
                      purchase(visitor: c[0], at: DAY + 1.hour, cents: 200),
                      purchase(visitor: 950, at: DAY + 1.hour, cents: 999)])
    out = experiment
    rows = out["groups"].index_by { |g| g["id"] }
    assert_equal [1000, 500], rows["a"].values_at("revenue_cents", "revenue_per_person_cents")
    assert_equal [0, nil], rows["b"].values_at("revenue_cents", "revenue_per_person_cents")
    assert_equal [200, 100], rows["control"].values_at("revenue_cents", "revenue_per_person_cents")
    assert_equal [4.0, 800], out.values_at("revenue_lift", "added_revenue_cents")
  end

  test "revenue follows the ledger's signs, quantities and the newest version of each purchase" do
    @campaign.update!(conversion: nil)
    a = people("a", 1).first
    insert_ch_events([event("in_app_viewed", visitor: a, at: DAY, campaign_id: @campaign.hashid)])
    at = DAY + 1.hour
    sub = { purchase_type: "subscription" }
    insert_purchases([purchase(visitor: a, at: at, cents: 100, txn: "qty", quantity: 3),
                      purchase(visitor: a, at: at, cents: 500, txn: "one"), purchase(visitor: a, at: at, cents: 500, txn: "one", type: "cancel"),
                      purchase(visitor: a, at: at, cents: 700, txn: "sub", **sub),
                      purchase(visitor: a, at: at, cents: 700, txn: "sub", type: "cancel", **sub),
                      purchase(visitor: a, at: at, cents: 200, txn: "rev"), purchase(visitor: a, at: at, cents: 200, txn: "rev", type: "refund"),
                      purchase(visitor: a, at: at, cents: 200, txn: "rev", type: "refund_reversed"),
                      purchase(visitor: a, at: at, cents: 1000, txn: "fix"), purchase(visitor: a, at: at, cents: 1500, txn: "fix", written: DAY + 80.hours),
                      purchase(visitor: 0, at: at, cents: 400, txn: "late"), purchase(visitor: a, at: at, cents: 400, txn: "late", written: DAY + 3.hours),
                      purchase(visitor: a, at: at, cents: 50, txn: "old", recorded_at: stamp(Time.at(0)))])
    revenue = experiment["groups"].find { |g| g["id"] == "a" }["revenue_cents"]
    assert_equal 300 + 0 + 700 + 200 + 1500 + 400 + 50, revenue, "qty, one-time cancel, sub cancel, reversal, fix, late, old"
  end

  test "a purchase goal converts on a buy of a listed product within 30 days, and on any buy without products" do
    @campaign.update!(conversion: { "purchase" => true, "products" => ["premium"], "window_hours" => 720 })
    a = people("a", 2)
    c = people("control", 1)
    mine = { campaign_id: @campaign.hashid }
    insert_ch_events([event("in_app_viewed", visitor: a[0], at: DAY, **mine), event("in_app_viewed", visitor: a[1], at: DAY, **mine),
                      event("in_app_held", visitor: c[0], at: DAY, **mine, scope: "campaign")])
    insert_purchases([purchase(visitor: a[0], at: DAY + 20.days, cents: 999),
                      purchase(visitor: a[1], at: DAY + 1.hour, cents: 100, product: "coins"),
                      purchase(visitor: c[0], at: DAY + 31.days, cents: 999)])
    rows = experiment["groups"].index_by { |g| g["id"] }
    assert_equal [1, 1099], rows["a"].values_at("converted", "revenue_cents")
    assert_equal [0, 0], rows["control"].values_at("converted", "revenue_cents")

    @campaign.update!(conversion: { "purchase" => true, "window_hours" => 720 })
    assert_equal 2, experiment["groups"].find { |g| g["id"] == "a" }["converted"]
  end

  test "without a goal revenue is counted over 72 hours" do
    @campaign.update!(conversion: nil)
    a = people("a", 1)
    insert_ch_events([event("in_app_viewed", visitor: a[0], at: DAY, campaign_id: @campaign.hashid)])
    insert_purchases([purchase(visitor: a[0], at: DAY + 70.hours, cents: 300), purchase(visitor: a[0], at: DAY + 73.hours, cents: 700)])
    out = experiment
    assert_nil out["goal"]
    assert_equal [nil, 300], out["groups"].find { |g| g["id"] == "a" }.values_at("converted", "revenue_cents")
  end

  test "revenue comparisons use unrounded figures and are null when a side is empty" do
    a = people("a", 4)
    c = people("control", 4)
    mine = { campaign_id: @campaign.hashid }
    insert_ch_events(a.map { |id| event("in_app_viewed", visitor: id, at: DAY, **mine) })
    insert_purchases([purchase(visitor: a[0], at: DAY + 1.hour, cents: 2), purchase(visitor: c[0], at: DAY + 1.hour, cents: 1)])
    out = experiment
    assert_equal [nil, nil], out.values_at("revenue_lift", "added_revenue_cents"), "no one in the control"

    insert_ch_events(c.map { |id| event("in_app_held", visitor: id, at: DAY, **mine, scope: "campaign") })
    Rails.cache.clear
    out = experiment
    rows = out["groups"].index_by { |g| g["id"] }
    assert_equal [1, 0], [rows["a"]["revenue_per_person_cents"], rows["control"]["revenue_per_person_cents"]]
    assert_equal [1.0, 1], out.values_at("revenue_lift", "added_revenue_cents")
  end

  test "people are grouped by their bucket, and converted when the goal follows exposure inside the window" do
    a = people("a", 3)
    b = people("b", 2)
    c = people("control", 2)
    mine = { campaign_id: @campaign.hashid }
    insert_ch_events([
                       event("in_app_viewed", visitor: a[0], at: DAY, **mine), event("in_app_viewed", visitor: a[0], at: DAY + 1.day, **mine),
                       event("in_app_clicked", visitor: a[0], at: DAY + 1.minute, **mine),
                       event("checkout", visitor: a[0], at: DAY + 2.hours),
                       event("in_app_viewed", visitor: a[1], at: DAY, **mine), event("checkout", visitor: a[1], at: DAY + 25.hours),
                       event("in_app_viewed", visitor: a[2], at: DAY, **mine), event("checkout", visitor: a[2], at: DAY - 1.hour),
                       event("in_app_viewed", visitor: b[0], at: DAY, **mine), event("checkout", visitor: b[0], at: DAY + 23.hours),
                       event("in_app_viewed", visitor: b[1], at: DAY + 2.days, **mine), event("checkout", visitor: b[1], at: DAY + 2.days + 20.hours),
                       event("in_app_held", visitor: c[0], at: DAY, **mine, scope: "campaign"), event("checkout", visitor: c[0], at: DAY + 1.hour),
                       event("in_app_held", visitor: c[1], at: DAY, **mine, scope: "campaign"),
                       event("in_app_held", visitor: 900, at: DAY, scope: "project"),
                       event("in_app_held", visitor: 901, at: DAY, scope: "project"), event("checkout", visitor: 901, at: DAY + 3.hours),
                       event("in_app_viewed", visitor: 950, at: DAY, campaign_id: "other"),
                       event("in_app_clicked", visitor: 951, at: DAY, **mine)
                     ])
    InAppSetting.create!(project: @project, control_group: 5)
    out = experiment
    assert_response :ok
    assert_equal({ "event" => "checkout", "window_hours" => 24 }, out["goal"])
    assert_equal [20, 5, nil], out.values_at("control_group", "project_control_group", "test_share")
    rows = out["groups"].index_by { |g| g["id"] }
    assert_equal %w[a b control project_control], rows.keys
    assert_equal [3, 1, 1, 0.3333, 0.3333], rows["a"].values_at("exposed", "clicked", "converted", "click_rate", "conversion_rate")
    assert_equal [2, 0, 2, 0.0, 1.0], rows["b"].values_at("exposed", "clicked", "converted", "click_rate", "conversion_rate")
    assert_equal [2, nil, 1, nil, 0.5], rows["control"].values_at("exposed", "clicked", "converted", "click_rate", "conversion_rate")
    assert_equal [2, nil, 1, nil, 0.5], rows["project_control"].values_at("exposed", "clicked", "converted", "click_rate", "conversion_rate")
    assert_equal 1, out["groups"].count { |g| g["id"] == "control" }, "a held person appears once"
    assert_equal [0.2, 1, nil, 301], out.values_at("lift", "added_conversions", "confidence", "more_people_needed")
    assert rows.values.all? { |g| g["confidence"].nil? }
  end

  test "with enough people the report says how sure it is, or how many more it needs" do
    a = people("a", 300)
    c = people("control", 300)
    mine = { campaign_id: @campaign.hashid }
    rows = a.each_with_index.flat_map do |id, i|
      [event("in_app_viewed", visitor: id, at: DAY, **mine)] + (i < 60 ? [event("checkout", visitor: id, at: DAY + 1.hour)] : [])
    end
    rows += c.each_with_index.flat_map do |id, i|
      [event("in_app_held", visitor: id, at: DAY, **mine, scope: "campaign")] + (i < 30 ? [event("checkout", visitor: id, at: DAY + 1.hour)] : [])
    end
    insert_ch_events(rows)
    out = experiment
    assert_equal [1.0, 30], out.values_at("lift", "added_conversions")
    assert_operator out["confidence"], :>=, 0.99
    assert_nil out["more_people_needed"]
    assert_nil out["groups"].find { |g| g["id"] == "b" }["confidence"]

    truncate_clickhouse_tables
    rows = a.each_with_index.flat_map do |id, i|
      [event("in_app_viewed", visitor: id, at: DAY, **mine)] + (i < 33 ? [event("checkout", visitor: id, at: DAY + 1.hour)] : [])
    end
    rows += c.each_with_index.flat_map do |id, i|
      [event("in_app_held", visitor: id, at: DAY, **mine, scope: "campaign")] + (i < 30 ? [event("checkout", visitor: id, at: DAY + 1.hour)] : [])
    end
    insert_ch_events(rows)
    Rails.cache.clear
    out = experiment
    assert_operator out["confidence"], :<, 0.95
    assert_operator out["more_people_needed"], :>, 1000
  end

  test "a button or an answer that exists only in variant B is accepted" do
    only_b = { "id" => "only_b", "text" => "Go", "action" => { "type" => "close" } }
    @campaign.update!(variants: [B.merge("content" => B["content"].merge("buttons" => [only_b]))])
    assert InAppEventCheck.accept(project: @project, visitor: visitors(:ios_visitor), name: "in_app_clicked",
                                  properties: { "campaign_id" => @campaign.hashid, "button_id" => "only_b" }, event_id: "x")
    assert_not InAppEventCheck.accept(project: @project, visitor: visitors(:ios_visitor), name: "in_app_clicked",
                                      properties: { "campaign_id" => @campaign.hashid, "button_id" => "nowhere" }, event_id: "x")
    silent = STARS.merge("comment" => nil)
    asked = live_in_app_campaign(@project, content: asking(silent), variants: [B.merge("content" => B["content"].merge("question" => STARS))])
    answer = { "campaign_id" => asked.hashid, "question_id" => "q1", "type" => "stars", "value" => 2 }
    assert InAppEventCheck.accept(project: @project, visitor: visitors(:ios_visitor), name: "in_app_answered", properties: answer, event_id: "x")
    assert InAppEventCheck.accept(project: @project, visitor: visitors(:ios_visitor), name: "in_app_commented",
                                  properties: answer.merge("comment" => "Only B asks"), event_id: "x")
  end

  test "a screen can be the goal" do
    @campaign.update!(conversion: { "screen" => "Checkout", "window_hours" => 24 })
    a = people("a", 2)
    mine = { campaign_id: @campaign.hashid }
    insert_ch_events([event("in_app_viewed", visitor: a[0], at: DAY, **mine), event("in_app_viewed", visitor: a[1], at: DAY, **mine),
                      event("screen_view", visitor: a[0], at: DAY + 1.hour).merge(event_type: "screen_view", screen_name: "Checkout"),
                      event("screen_view", visitor: a[1], at: DAY + 1.hour).merge(event_type: "screen_view", screen_name: "Cart"),
                      event("Checkout", visitor: a[1], at: DAY + 1.hour)])
    out = experiment
    assert_equal({ "screen" => "Checkout", "window_hours" => 24 }, out["goal"])
    assert_equal [2, 1, 0.5], out["groups"].first.values_at("exposed", "converted", "conversion_rate")
  end

  test "a system event can be the goal, and a type it does not know is refused" do
    @campaign.update!(conversion: { "system" => "reactivation", "window_hours" => 24 })
    a = people("a", 2)
    mine = { campaign_id: @campaign.hashid }
    insert_ch_events([event("in_app_viewed", visitor: a[0], at: DAY, **mine), event("in_app_viewed", visitor: a[1], at: DAY, **mine),
                      event("", visitor: a[0], at: DAY + 1.hour).merge(event_type: "reactivation"),
                      event("reactivation", visitor: a[1], at: DAY + 1.hour)])
    out = experiment
    assert_equal({ "system" => "reactivation", "window_hours" => 24 }, out["goal"])
    assert_equal [2, 1], out["groups"].first.values_at("exposed", "converted")
    assert_nil Experiments::Goal.problem({ "system" => "install", "window_hours" => 72 })
    assert_not_nil Experiments::Goal.problem({ "system" => "user_referred", "window_hours" => 24 })
    assert_not @campaign.update(conversion: { "system" => "user_referred", "window_hours" => 24 })
  end

  test "without a goal the variants are compared on clicks; without any experiment there is nothing to report" do
    @campaign.update!(conversion: nil)
    a = people("a", 1)
    mine = { campaign_id: @campaign.hashid }
    insert_ch_events([event("in_app_viewed", visitor: a[0], at: DAY, **mine), event("in_app_clicked", visitor: a[0], at: DAY, **mine)])
    out = experiment
    assert_nil out["goal"]
    assert_equal [1, 1, nil, 1.0, nil], out["groups"].first.values_at("exposed", "clicked", "converted", "click_rate", "conversion_rate")
    assert_equal [nil, nil, nil, nil], out.values_at("lift", "added_conversions", "confidence", "more_people_needed")

    plain = live_in_app_campaign(@project)
    experiment(plain)
    assert_response :unprocessable_entity
    experiment(from: "2026-01-01", to: "2026-09-22")
    assert_response :unprocessable_entity
  end
end
