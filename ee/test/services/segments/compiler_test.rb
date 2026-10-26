require "test_helper"

class SegmentsCompilerTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  PID = 9_202
  NOW = Time.utc(2026, 9, 17, 12)
  CUTOFF = Date.new(2026, 1, 1)

  setup do
    skip_unless_clickhouse!
    @__clickhouse_test_started = true
    @ch_auto_rebuild_breakdowns = true
  end

  def ev(visitor, name: "", type: "custom", at: "2026-09-10 10:00:00.000", **extra)
    { project_id: PID, visitor_id: visitor, event_type: type, event_name: name, created_at: at }.merge(extra)
  end

  def profile(visitor, ident, props = {}, platform: "", last_seen: "2026-09-01 00:00:00.000")
    { project_id: PID, visitor_id: visitor, sdk_identifier: ident, properties: props, platform: platform,
      first_seen: "2026-09-01 00:00:00.000", last_seen: last_seen }
  end

  def event_cond(name, extra = {})
    { "type" => "event", "event_name" => name, "window" => { "last_days" => 30 } }.merge(extra)
  end

  def any_cond(days, extra = {})
    { "type" => "event", "any" => true, "window" => { "last_days" => days } }.merge(extra)
  end

  def type_cond(type, extra = {})
    { "type" => "event", "event_type" => type, "window" => { "last_days" => 30 } }.merge(extra)
  end

  def compile(groups, operator: "or", cutoff: CUTOFF)
    d = Segments::Definition.parse({ "version" => 1, "operator" => operator, "groups" => groups }, cutoff_date: cutoff)
    raise d.errors.inspect unless d.valid?

    Segments::Compiler.new(d, project_id: PID, cutoff_date: cutoff, now: NOW)
  end

  def persons(compiler)
    Clickhouse.with { |c| c.select_all(compiler.members_sql) }.map { |r| r["pk"] }.sort
  end

  def and_group(*conds) = { "operator" => "and", "conditions" => conds }
  def or_group(*conds) = { "operator" => "or", "conditions" => conds }

  test "a count threshold is reached across two devices of one person" do
    insert_ch_user_profiles([profile(1, "ana"), profile(2, "ana"), profile(3, "bob")])
    insert_ch_events([ev(1, name: "checkout"), ev(1, name: "checkout"), ev(2, name: "checkout"), ev(3, name: "checkout")])
    assert_equal ["i:ana"], persons(compile([and_group(event_cond("checkout", "count" => 3))]))
  end

  test "a replayed duplicate event is counted once" do
    insert_ch_user_profiles([profile(1, "")])
    insert_ch_events([ev(1, name: "checkout", event_id: "dup-1"), ev(1, name: "checkout", event_id: "dup-1")])
    assert_empty persons(compile([and_group(event_cond("checkout", "count" => 2))]))
  end

  test "a future-dated event never matches a rolling window" do
    insert_ch_user_profiles([profile(1, "")])
    insert_ch_events([ev(1, name: "checkout", at: "2027-01-01 00:00:00.000")])
    assert_empty persons(compile([and_group(event_cond("checkout"))]))
  end

  test "all four operator combinations evaluate per their operators" do
    insert_ch_user_profiles([profile(1, ""), profile(2, ""), profile(3, "")])
    insert_ch_events([ev(1, name: "a"), ev(1, name: "b"), ev(2, name: "a"), ev(3, name: "c")])
    a = event_cond("a")
    b = event_cond("b")
    c = event_cond("c")
    assert_equal %w[v:1 v:3], persons(compile([and_group(a, b), and_group(c)], operator: "or"))
    assert_equal %w[v:1 v:2 v:3], persons(compile([or_group(a, b), or_group(c)], operator: "or"))
    assert_equal %w[v:1], persons(compile([or_group(a, c), or_group(b)], operator: "and"))
    assert_empty persons(compile([and_group(a, b), and_group(c)], operator: "and"))
  end

  test "negation subtracts from the group's positive set" do
    insert_ch_user_profiles([profile(1, ""), profile(2, "")])
    insert_ch_events([ev(1, name: "a"), ev(1, name: "b"), ev(2, name: "a")])
    assert_equal ["v:2"], persons(compile([and_group(event_cond("a"), event_cond("b", "negate" => true))]))
  end

  test "a merged-away visitor's events count toward the survivor and both ids are members" do
    insert_ch_user_profiles([profile(11, "bob")])
    Clickhouse.with do |c|
      c.insert("visitor_identity_map", [{ project_id: PID, from_visitor_id: 10, to_visitor_id: 11, updated_at: "2026-09-05 00:00:00.000" }])
    end
    insert_ch_events([ev(10, name: "checkout"), ev(11, name: "checkout")])
    compiler = compile([and_group(event_cond("checkout", "count" => 2))])
    row = Clickhouse.with { |c| c.select_all(compiler.members_sql) }.first
    assert_equal "i:bob", row["pk"]
    assert_equal [[10, 11], [11, 11]], row["members"].map { |m| m.map(&:to_i) }.sort
  end

  test "a visitor with events but no identity row is kept as its own person" do
    insert_ch_events([ev(77, name: "checkout")])
    assert_equal ["v:77"], persons(compile([and_group(event_cond("checkout"))]))
  end

  test "a merge survivor with no identifier and no profile row is still a person, with both raw ids as members" do
    Clickhouse.with do |c|
      c.insert("visitor_identity_map", [{ project_id: PID, from_visitor_id: 40, to_visitor_id: 41, updated_at: "2026-09-05 00:00:00.000" }])
    end
    insert_ch_events([ev(40, name: "checkout")])
    row = Clickhouse.with { |c| c.select_all(compile([and_group(event_cond("checkout"))]).members_sql) }.first
    assert_equal "v:41", row["pk"]
    assert_equal [[40, 41], [41, 41]], row["members"].map { |m| m.map(&:to_i) }.sort
  end

  test "anonymous unmerged visitors with only profile rows are their own persons" do
    insert_ch_user_profiles([profile(1, ""), profile(2, "")])
    insert_ch_events([ev(1, name: "a"), ev(2, name: "a")])
    assert_equal %w[v:1 v:2], persons(compile([and_group(event_cond("a"))]))
    row = Clickhouse.with { |c| c.select_all(compile([and_group(event_cond("a"))]).estimate_sql) }.first
    assert_equal 2, row["persons"].to_i
    assert_equal 2, row["devices"].to_i
  end

  test "device current platform comes from the profile's latest row and profile reads current properties" do
    insert_ch_user_profiles([profile(1, "", { "plan" => "pro" }, platform: "android", last_seen: "2026-09-01 10:00:00.000"),
                             profile(1, "", { "plan" => "pro" }, platform: "ios", last_seen: "2026-09-12 10:00:00.000"),
                             profile(2, "", { "plan" => "free" }, platform: "ios"),
                             profile(3, "", { "plan" => "pro" }, platform: "ios", last_seen: "2026-07-01 10:00:00.000")])
    insert_ch_events([ev(1, name: "x", platform: "ios"), ev(2, name: "x", platform: "ios"), ev(3, name: "x", platform: "ios")])
    ios = { "type" => "device", "field" => "platform", "op" => "is", "value" => ["ios"] }
    pro = { "type" => "profile", "field" => "properties.plan", "op" => "is", "value" => "pro" }
    assert_equal %w[v:1 v:2], persons(compile([and_group(ios)]))
    assert_equal %w[v:1], persons(compile([and_group(ios, pro)]))
  end

  test "current platform is_not matches only people with a known current platform" do
    insert_ch_user_profiles([profile(1, "", platform: "ios"), profile(2, "", platform: "web"),
                             profile(3, "", platform: "android", last_seen: "2026-07-01 10:00:00.000")])
    insert_ch_events([ev(1, name: "a"), ev(2, name: "a"), ev(3, name: "a"), ev(4, name: "a")])
    not_web = { "type" => "device", "field" => "platform", "op" => "is_not", "value" => ["web"] }
    assert_equal %w[v:1], persons(compile([and_group(event_cond("a"), not_web)]))
    assert_equal %w[v:1], persons(compile([and_group(not_web)]))
  end

  test "device current app_version still comes from the person's latest event" do
    insert_ch_user_profiles([profile(1, "", platform: "ios")])
    insert_ch_events([ev(1, name: "x", app_version: "3.1", at: "2026-09-01 10:00:00.000"),
                      ev(1, name: "x", app_version: "3.2", at: "2026-09-12 10:00:00.000")])
    latest = { "type" => "device", "field" => "app_version", "op" => "is", "value" => ["3.2"] }
    old = { "type" => "device", "field" => "app_version", "op" => "is", "value" => ["3.1"] }
    assert_equal %w[v:1], persons(compile([and_group(latest)]))
    assert_equal [], persons(compile([and_group(old)]))
  end

  test "first_seen filters on the person's earliest built-in event" do
    insert_ch_user_profiles([profile(1, ""), profile(2, "")])
    insert_ch_events([ev(1, type: "install", at: "2026-06-05 00:00:00.000"), ev(2, type: "install", at: "2026-08-05 00:00:00.000")])
    recent = { "type" => "first_seen", "op" => "gte", "value" => "2026-08-01" }
    assert_equal ["v:2"], persons(compile([and_group(recent)]))
  end

  test "any-activity reads the daily rollup and respects its window" do
    insert_ch_user_profiles([profile(1, ""), profile(2, "")])
    insert_ch_events([ev(1, type: "app_open", at: "2026-09-15 10:00:00.000"), ev(2, type: "app_open", at: "2026-07-01 10:00:00.000")])
    assert_equal ["v:1"], persons(compile([and_group(any_cond(7))]))
    assert_equal ["v:2"], persons(compile([and_group(any_cond(90), any_cond(7, "negate" => true))]))
  end

  test "a built-in event_type count is merge-aware and reads the daily rollup across two devices" do
    insert_ch_user_profiles([profile(1, "bob"), profile(2, "bob")])
    insert_ch_events([ev(1, type: "app_open"), ev(1, type: "app_open"), ev(2, type: "app_open")])
    assert_equal ["i:bob"], persons(compile([and_group(type_cond("app_open", "count" => 3))]))
  end

  test "a duplicate app_open event_id does not double count via the daily rollup path" do
    insert_ch_user_profiles([profile(1, "")])
    insert_ch_events([ev(1, type: "app_open", event_id: "dup-ao"), ev(1, type: "app_open", event_id: "dup-ao")])
    assert_empty persons(compile([and_group(type_cond("app_open", "count" => 2))]))
  end

  test "an app_open dated after the window's last day does not match the rollup path" do
    insert_ch_user_profiles([profile(1, "")])
    insert_ch_events([ev(1, type: "app_open", at: "2027-01-01 00:00:00.000")])
    assert_empty persons(compile([and_group(type_cond("app_open"))]))
  end

  test "the rollup count sums across day and platform rows, not just one" do
    insert_ch_user_profiles([profile(1, "")])
    insert_ch_events([ev(1, type: "app_open", platform: "ios", at: "2026-09-10 10:00:00.000"),
                      ev(1, type: "app_open", platform: "ios", at: "2026-09-11 10:00:00.000"),
                      ev(1, type: "app_open", platform: "android", at: "2026-09-10 10:00:00.000")])
    assert_equal ["v:1"], persons(compile([and_group(type_cond("app_open", "count" => 3))]))
    assert_empty persons(compile([and_group(type_cond("app_open", "count" => 4))]))
  end

  test "properties.platform means the JSON property, never the top-level column" do
    insert_ch_user_profiles([profile(1, ""), profile(2, "")])
    insert_ch_events([ev(1, name: "buy", platform: "ios", properties: { "platform" => "kiosk" }),
                       ev(2, name: "buy", platform: "android", properties: { "platform" => "ios" })])
    prop_filter = event_cond("buy", "filters" => [{ "field" => "properties.platform", "op" => "is", "value" => ["ios"] }])
    top_filter = event_cond("buy", "filters" => [{ "field" => "platform", "op" => "is", "value" => ["ios"] }])
    assert_equal ["v:2"], persons(compile([and_group(prop_filter)]))
    assert_equal ["v:1"], persons(compile([and_group(top_filter)]))
  end

  test "estimate counts persons and effective devices" do
    insert_ch_user_profiles([profile(1, "ana"), profile(2, "ana"), profile(3, "")])
    insert_ch_events([ev(1, name: "a"), ev(3, name: "a")])
    row = Clickhouse.with { |c| c.select_all(compile([and_group(event_cond("a"))]).estimate_sql) }.first
    assert_equal 2, row["persons"].to_i
    assert_equal 3, row["devices"].to_i
  end

  test "members_sql carries its own join_use_nulls = 0, immune to the caller's session setting" do
    insert_ch_events([ev(77, name: "checkout")])
    sql = compile([and_group(event_cond("checkout"))]).members_sql
    rows = Clickhouse.with { |c| c.select_all("SELECT * FROM (#{sql}) SETTINGS join_use_nulls = 1") }
    assert_equal ["v:77"], rows.map { |r| r["pk"] }
  end

  test "estimate counts a merged-away alias as one device, not two" do
    insert_ch_user_profiles([profile(11, "bob")])
    Clickhouse.with do |c|
      c.insert("visitor_identity_map", [{ project_id: PID, from_visitor_id: 10, to_visitor_id: 11, updated_at: "2026-09-05 00:00:00.000" }])
    end
    insert_ch_events([ev(10, name: "checkout"), ev(11, name: "checkout")])
    row = Clickhouse.with { |c| c.select_all(compile([and_group(event_cond("checkout", "count" => 2))]).estimate_sql) }.first
    assert_equal 1, row["persons"].to_i
    assert_equal 1, row["devices"].to_i
  end

  test "identifier conditions work per person and in_list reads the published generation" do
    insert_ch_user_profiles([profile(1, "Ana@x.io"), profile(2, "Ana@x.io"), profile(3, "bob@x.io"), profile(4, "")])
    insert_ch_events([ev(1, name: "a"), ev(3, name: "a"), ev(4, name: "a")])
    gen = "c" * 32
    Clickhouse.with do |c|
      c.insert("segment_identifier_entries", [{ project_id: PID, segment_id: 77, generation: gen, identifier: "bob@x.io" },
                                              { project_id: PID, segment_id: 77, generation: "d" * 32, identifier: "Ana@x.io" }])
    end
    did_a = event_cond("a")
    compiled = lambda do |cond|
      d = Segments::Definition.parse({ "version" => 1, "operator" => "or", "groups" => [and_group(did_a, cond)] }, cutoff_date: CUTOFF)
      Segments::Compiler.new(d, project_id: PID, cutoff_date: CUTOFF, now: NOW, segment_id: 77, list_generation: gen)
    end
    assert_equal %w[i:Ana@x.io i:bob@x.io], persons(compiled.call("type" => "identifier", "op" => "is_set"))
    assert_equal %w[v:4], persons(compiled.call("type" => "identifier", "op" => "is_not_set"))
    assert_equal %w[i:Ana@x.io], persons(compiled.call("type" => "identifier", "op" => "is", "value" => ["Ana@x.io"]))
    assert_empty persons(compiled.call("type" => "identifier", "op" => "is", "value" => ["ana@x.io"]))
    assert_equal %w[i:bob@x.io], persons(compiled.call("type" => "identifier", "op" => "in_list"))
  end

  test "acquisition matches persons by campaign_id on install events only" do
    insert_ch_user_profiles([profile(1, ""), profile(2, ""), profile(3, "")])
    insert_ch_events([ev(1, type: "install", campaign_id: 12), ev(2, type: "install", campaign_id: 99),
                       ev(3, name: "checkout", campaign_id: 12)])
    campaign_12 = { "type" => "acquisition", "field" => "campaign_id", "op" => "is", "value" => [12], "window" => { "last_days" => 30 } }
    did_a = event_cond("a")
    assert_equal ["v:1"], persons(compile([and_group(campaign_12)]))
    insert_ch_events([ev(1, name: "a"), ev(2, name: "a"), ev(3, name: "a")])
    not_campaign_12 = campaign_12.merge("op" => "is_not")
    assert_equal %w[v:2 v:3], persons(compile([and_group(did_a, not_campaign_12)]))
  end

  test "an aged-out window is flagged incomplete, and refused when the condition is negative" do
    june = { "from" => "2026-06-01", "to" => "2026-06-30" }
    parsed_cutoff = Date.new(2026, 1, 1)
    d = Segments::Definition.parse({ "version" => 1, "operator" => "or", "groups" => [
                                     and_group(event_cond("a"), event_cond("b", "window" => june, "negate" => true))
                                   ] }, cutoff_date: parsed_cutoff)
    late = Segments::Compiler.new(d, project_id: PID, cutoff_date: Date.new(2026, 6, 15), now: NOW)
    assert late.incomplete?
    assert_raises(Segments::WindowExpired) { late.members_sql }
    assert_raises(Segments::WindowExpired) { late.estimate_sql }
  end

  def purchase(visitor, txn, type, product: "pro", price: 1_000, qty: 1, at: "2026-09-10 10:00:00.000",
               purchase_type: "subscription", store: "apple")
    { project_id: PID, event_type: type, purchase_type: purchase_type, product_id: product,
      usd_price_cents: price, currency: "usd", quantity: qty, transaction_id: txn, original_transaction_id: txn,
      store_source: store, device_id: 0, link_id: 0, visitor_id: visitor, purchase_date: at, created_at: at }
  end

  def purchase_cond(extra = {})
    { "type" => "purchase", "product_id" => ["pro"], "window" => { "last_days" => 90 } }.merge(extra)
  end

  test "purchase conditions count eligible transactions and sum spend, refund-aware" do
    insert_ch_events([ev(1, name: "a"), ev(2, name: "a"), ev(3, name: "a"), ev(4, name: "a"), ev(5, name: "a")])
    Clickhouse.with do |c|
      c.insert("purchase_events", [
                 purchase(1, "t-v1", "buy"),
                 purchase(1, "t-v1-old", "buy", at: "2025-08-14 10:00:00.000"),
                 purchase(2, "t-v2", "buy"),
                 purchase(2, "t-v2", "refund"),
                 purchase(3, "t-v3", "buy"),
                 purchase(3, "t-v3", "refund"),
                 purchase(3, "t-v3", "refund_reversed"),
                 purchase(4, "t-v4-a", "buy", qty: 3),
                 purchase(4, "t-v4-b", "buy", qty: 1),
                 purchase(5, "t-v5", "buy", product: "other"),
                 purchase(0, "t-v0", "buy")
               ])
    end
    assert_equal %w[v:1 v:3 v:4], persons(compile([and_group(purchase_cond("count" => 1))]))
    assert_equal ["v:4"], persons(compile([and_group(purchase_cond("count" => 2))]))
    assert_equal ["v:4"], persons(compile([and_group(purchase_cond("min_total_usd_cents" => 3_500))]))
    did_a = event_cond("a")
    not_pro = purchase_cond("negate" => true)
    assert_equal %w[v:2 v:5], persons(compile([and_group(did_a, not_pro)]))
  end

  test "purchase history is cut at the window start yet a refund dated or recorded after the window still counts" do
    insert_ch_events((1..5).map { |v| ev(v, name: "a") })
    late = "2026-09-20 10:00:00.000"
    Clickhouse.with do |c|
      c.insert("purchase_events", [
                 purchase(1, "t-1", "buy", at: "2026-09-03 10:00:00.000"),
                 purchase(1, "t-1", "refund", at: "2026-09-03 10:00:00.000").merge(created_at: late),
                 purchase(2, "t-2", "buy", at: "2026-09-03 10:00:00.000"),
                 purchase(2, "t-2", "refund", at: late),
                 purchase(3, "t-3", "buy", at: "2026-09-03 10:00:00.000"),
                 purchase(4, "t-4", "buy", at: "2026-08-20 10:00:00.000"),
                 purchase(5, "t-5", "buy", at: "2026-08-31 23:00:00.000")
               ])
    end
    window = { "from" => "2026-09-01", "to" => "2026-09-05" }
    assert_equal ["v:3"], persons(compile([and_group(purchase_cond("window" => window))]))
  end

  test "a Google refund, filed under <txn>_refund, disqualifies its buy; Apple refunds still group by transaction" do
    insert_ch_events((1..4).map { |v| ev(v, name: "a") })
    later = "2026-09-12 10:00:00.000"
    Clickhouse.with do |c|
      c.insert("purchase_events", [
                 purchase(1, "g-1", "buy", store: "google"),
                 purchase(0, "g-1_refund", "refund", store: "google", at: later),
                 purchase(2, "g-2", "buy", store: "google"),
                 purchase(3, "a-3", "buy"),
                 purchase(3, "a-3", "refund"),
                 purchase(4, "a-4", "buy"),
                 purchase(4, "a-4_refund", "refund")
               ])
    end
    assert_equal %w[v:2 v:4], persons(compile([and_group(purchase_cond)]))
  end

  test "purchase conditions merge across an identified person's devices, tolerate a bare cancel, and filter by purchase_type/store_source" do
    insert_ch_user_profiles([profile(101, "carol"), profile(102, "carol")])
    Clickhouse.with do |c|
      c.insert("purchase_events", [
                 purchase(101, "t-carol-a", "buy", price: 800),
                 purchase(102, "t-carol-b", "buy", price: 900),
                 purchase(103, "t-cancel-only", "buy"),
                 purchase(103, "t-cancel-only", "cancel"),
                 purchase(104, "t-sub", "buy", product: "pro_filter", price: 500),
                 purchase(105, "t-onetime", "buy", product: "pro_filter", price: 500, purchase_type: "one_time", store: "google")
               ])
    end
    assert_includes persons(compile([and_group(purchase_cond("count" => 2))])), "i:carol"
    assert_includes persons(compile([and_group(purchase_cond("min_total_usd_cents" => 1_500))])), "i:carol"
    assert_includes persons(compile([and_group(purchase_cond("count" => 1))])), "v:103"
    sub_filter = purchase_cond("product_id" => ["pro_filter"], "purchase_type" => ["subscription"])
    assert_equal ["v:104"], persons(compile([and_group(sub_filter)]))
    apple_filter = purchase_cond("product_id" => ["pro_filter"], "store_source" => ["apple"])
    assert_equal ["v:104"], persons(compile([and_group(apple_filter)]))
  end

  def estimate_with_platforms(compiler)
    Clickhouse.with { |c| c.select_all(compiler.estimate_with_platforms_sql) }.first
  end

  test "estimate_with_platforms_sql matches the baseline persons/devices and splits by current platform" do
    insert_ch_user_profiles([profile(1, "", platform: "ios"), profile(2, "", platform: "android"),
                              profile(3, "", platform: "ios"), profile(4, "", platform: "")])
    insert_ch_events([ev(1, name: "checkout"), ev(2, name: "checkout"), ev(3, name: "checkout"), ev(4, name: "checkout")])

    compiler = compile([and_group(event_cond("checkout"))])
    baseline = Clickhouse.with { |c| c.select_all(compiler.estimate_sql) }.first
    result = estimate_with_platforms(compiler)

    assert_equal baseline["persons"].to_i, result["persons"].to_i
    assert_equal baseline["devices"].to_i, result["devices"].to_i
    assert_equal [4, 2, 1], [result["devices"].to_i, result["ios_devices"].to_i, result["android_devices"].to_i]
  end

  test "estimate_with_platforms_sql takes a merged device's platform from the survivor, which delivery uses" do
    insert_ch_user_profiles([profile(10, "", platform: "ios"), profile(11, "", platform: "android")])
    Clickhouse.with do |c|
      c.insert("visitor_identity_map", [{ project_id: PID, from_visitor_id: 10, to_visitor_id: 11, updated_at: "2026-09-05 00:00:00.000" }])
    end
    insert_ch_events([ev(10, name: "checkout"), ev(11, name: "checkout")])
    result = estimate_with_platforms(compile([and_group(event_cond("checkout"))]))
    assert_equal [1, 0, 1], [result["devices"].to_i, result["ios_devices"].to_i, result["android_devices"].to_i]
  end

  test "estimate_with_platforms_sql's approximate split is within tolerance on a larger fixture" do
    ios = (101..130).to_a
    android = (201..215).to_a
    insert_ch_user_profiles(ios.map { |v| profile(v, "", platform: "ios") } + android.map { |v| profile(v, "", platform: "android") })
    insert_ch_events((ios + android).map { |v| ev(v, name: "checkout") })

    result = estimate_with_platforms(compile([and_group(event_cond("checkout"))]))
    assert_equal 45, result["devices"].to_i
    assert_in_delta 30, result["ios_devices"].to_i, 2
    assert_in_delta 15, result["android_devices"].to_i, 2
  end

  test "estimate_with_platforms_sql never turns an active-but-unmatched visitor into a match" do
    insert_ch_user_profiles([profile(5, "", platform: "ios"), profile(6, "", platform: "android")])
    insert_ch_events([ev(5, name: "other")])

    negated = compile([and_group(event_cond("other"), event_cond("checkout", "negate" => true))])
    baseline = Clickhouse.with { |c| c.select_all(negated.estimate_sql) }.first
    result = estimate_with_platforms(negated)
    assert_equal [1, 1], [baseline["persons"].to_i, baseline["devices"].to_i], "did other, never did checkout: a real match"
    assert_equal [1, 1], [result["persons"].to_i, result["devices"].to_i], "the tag-only visitor 6 must not join this match"

    tag_only = compile([and_group(event_cond("checkout"))])
    result = estimate_with_platforms(tag_only)
    assert_equal [0, 0], [result["persons"].to_i, result["devices"].to_i]
  end

  test "estimate_with_platforms_sql buckets a stale (>30d) profile as neither ios nor android" do
    insert_ch_user_profiles([profile(6, "", platform: "ios", last_seen: "2026-01-01 00:00:00.000")])
    insert_ch_events([ev(6, name: "checkout")])
    result = estimate_with_platforms(compile([and_group(event_cond("checkout"))]))
    assert_equal [1, 0, 0], [result["devices"].to_i, result["ios_devices"].to_i, result["android_devices"].to_i]
  end

  def assert_platform_parity(compiler, label)
    baseline = Clickhouse.with { |c| c.select_all(compiler.estimate_sql) }.first
    result = estimate_with_platforms(compiler)
    assert_equal [baseline["persons"].to_i, baseline["devices"].to_i], [result["persons"].to_i, result["devices"].to_i], label
  end

  test "estimate_with_platforms_sql matches estimate_sql for every condition type" do
    insert_ch_user_profiles([profile(1, "ana", { "plan" => "pro" }, platform: "ios"),
                              profile(2, "ana", platform: "android"), profile(3, "bob@x.io", platform: "ios")])
    insert_ch_events([ev(1, name: "checkout"), ev(2, name: "checkout"),
                      ev(1, type: "install", campaign_id: 12, at: "2026-09-01 00:00:00.000"),
                      ev(3, type: "install", at: "2026-06-05 00:00:00.000")])
    Clickhouse.with { |c| c.insert("purchase_events", [purchase(1, "t-parity", "buy")]) }

    event = event_cond("checkout")
    device = { "type" => "device", "field" => "platform", "op" => "is", "value" => ["ios"] }
    profile_field = { "type" => "profile", "field" => "properties.plan", "op" => "is", "value" => "pro" }
    first_seen = { "type" => "first_seen", "op" => "gte", "value" => "2026-01-01" }
    identifier = { "type" => "identifier", "op" => "is_set" }
    acquisition = { "type" => "acquisition", "field" => "campaign_id", "op" => "is", "value" => [12], "window" => { "last_days" => 30 } }

    { "event" => event, "device" => device, "profile" => profile_field, "first_seen" => first_seen,
      "identifier" => identifier, "acquisition" => acquisition, "purchase" => purchase_cond }.each do |label, cond|
      assert_platform_parity(compile([and_group(cond)]), label)
    end
    assert_platform_parity(compile([and_group(event, device, profile_field)]), "combined AND")
    assert_platform_parity(compile([or_group(event), or_group(acquisition)], operator: "or"), "combined OR")
    assert_platform_parity(compile([and_group(event, device.merge("op" => "is_not"))]), "negative device")
  end
end

class SegmentsCompilerGuardTest < ActiveSupport::TestCase
  test "a definition that failed to parse must never compile" do
    invalid = Segments::Definition.parse({ "version" => 1, "operator" => "or", "groups" => [] }, cutoff_date: Date.new(2026, 1, 1))
    assert_not invalid.valid?
    assert_raises(Segments::InvalidDefinition) { Segments::Compiler.new(invalid, project_id: 9_202, cutoff_date: Date.new(2026, 1, 1)) }
  end

  test "the raised message names the failing path" do
    cutoff = Date.new(2026, 1, 1)
    invalid = Segments::Definition.parse({ "version" => 1, "operator" => "or", "groups" => [
                                           { "operator" => "and", "conditions" => [
                                             { "type" => "event", "event_name" => "a", "window" => { "last_days" => 9_999 } }
                                           ] }
                                         ] }, cutoff_date: cutoff)
    assert_not invalid.valid?
    error = assert_raises(Segments::InvalidDefinition) { Segments::Compiler.new(invalid, project_id: 9_202, cutoff_date: cutoff) }
    assert_includes error.message, "groups[0].conditions[0].window"
  end

  def device_compiler(op_name)
    cutoff = Date.new(2026, 9, 7)
    now = Time.utc(2026, 9, 17, 12)
    cond = { "type" => "device", "field" => "platform", "op" => op_name, "value" => ["ios"], "mode" => "current" }
    positive = { "type" => "event", "event_name" => "checkout", "window" => { "last_days" => 1 } }
    conditions = op_name == "is_not" ? [cond, positive] : [cond]
    d = Segments::Definition.parse({ "version" => 1, "operator" => "or",
                                      "groups" => [{ "operator" => "and", "conditions" => conditions }] }, cutoff_date: cutoff)
    raise d.errors.inspect unless d.valid?

    Segments::Compiler.new(d, project_id: 9_202, cutoff_date: cutoff, now: now)
  end

  test "a current device is_not past retention is merely incomplete, as unknown devices never match it" do
    compiler = device_compiler("is_not")
    assert compiler.incomplete?
    assert compiler.members_sql
  end

  test "a positive current device condition past retention is merely incomplete" do
    assert device_compiler("is").incomplete?
  end
end
