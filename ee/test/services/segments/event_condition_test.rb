require "test_helper"

class SegmentsEventConditionTest < ActiveSupport::TestCase
  Env = Struct.new(:project_id, :cutoff_date, :now)
  ENV_ = Env.new(7, Date.new(2026, 1, 1), Time.utc(2026, 9, 17, 12))

  def build(raw)
    errors = []
    [Segments::EventCondition.build(raw, path: "c", errors: errors, cutoff_date: ENV_.cutoff_date), errors]
  end

  test "normalises a custom-event condition with defaults" do
    c, errors = build("type" => "event", "event_name" => "checkout", "window" => { "last_days" => 30 })
    assert_empty errors
    assert_equal({ "type" => "event", "event_name" => "checkout", "filters" => [],
                   "count" => 1, "window" => { "last_days" => 30 }, "negate" => false }, c.to_h)
    assert_not c.negative?
  end

  test "to_h round-trips through build for each match kind" do
    [
      { "type" => "event", "event_type" => "install", "window" => { "last_days" => 1 } },
      { "type" => "event", "event_name" => "checkout", "window" => { "last_days" => 1 } },
      { "type" => "event", "any" => true, "window" => { "last_days" => 1 } }
    ].each do |raw|
      c, errors = build(raw)
      assert_empty errors
      c2, errors2 = build(c.to_h)
      assert_empty errors2
      assert_equal c.to_h, c2.to_h
    end
  end

  test "exactly one of event_type, event_name, any is required" do
    _, e1 = build("type" => "event", "window" => { "last_days" => 1 })
    _, e2 = build("type" => "event", "event_name" => "a", "any" => true, "window" => { "last_days" => 1 })
    assert_equal 1, e1.size
    assert_equal 1, e2.size
  end

  test "unknown built-in event type is rejected" do
    _, errors = build("type" => "event", "event_type" => "teleport", "window" => { "last_days" => 1 })
    assert_match(/event_type/, errors.first[:message])
  end

  test "count must be a positive integer" do
    _, errors = build("type" => "event", "event_name" => "a", "count" => 0, "window" => { "last_days" => 1 })
    assert_match(/count/, errors.first[:message])
  end

  test "count rejects fractional or non-numeric values, never truncating silently" do
    _, e1 = build("type" => "event", "event_name" => "a", "count" => 2.7, "window" => { "last_days" => 1 })
    _, e2 = build("type" => "event", "event_name" => "a", "count" => "3x", "window" => { "last_days" => 1 })
    _, e3 = build("type" => "event", "event_name" => "a", "count" => true, "window" => { "last_days" => 1 })
    assert_match(/count/, e1.first[:message])
    assert_match(/count/, e2.first[:message])
    assert_match(/count/, e3.first[:message])
    c, e4 = build("type" => "event", "event_name" => "a", "count" => "3", "window" => { "last_days" => 1 })
    assert_empty e4
    assert_equal 3, c.to_h["count"]
  end

  test "event_name must be a string of at most 256 bytes, never .to_s-ed" do
    _, e1 = build("type" => "event", "event_name" => "a" * 257, "window" => { "last_days" => 1 })
    _, e2 = build("type" => "event", "event_name" => { "a" => 1 }, "window" => { "last_days" => 1 })
    assert_match(/event_name/, e1.first[:message])
    assert_match(/event_name/, e2.first[:message])
    c, e3 = build("type" => "event", "event_name" => "a" * 256, "window" => { "last_days" => 1 })
    assert_empty e3
    assert_equal "a" * 256, c.to_h["event_name"]
  end

  test "filters accept allow-listed columns and valid property keys only" do
    ok, e_ok = build("type" => "event", "event_name" => "a", "window" => { "last_days" => 1 },
                     "filters" => [{ "field" => "properties.plan", "op" => "is", "value" => "pro" },
                                   { "field" => "country", "op" => "is_not", "value" => %w[RO] }])
    assert_empty e_ok
    assert_equal "properties.plan", ok.to_h["filters"].first["field"]
    _, e_bad = build("type" => "event", "event_name" => "a", "window" => { "last_days" => 1 },
                     "filters" => [{ "field" => "properties.bad`key", "op" => "is", "value" => "x" }])
    assert_equal 1, e_bad.size
  end

  test "rows_sql scans events with project, window, match and dedups by event_id" do
    c, = build("type" => "event", "event_name" => "o'hare", "count" => 3, "window" => { "last_days" => 1 },
               "filters" => [{ "field" => "properties.plan", "op" => "is", "value" => "pro" }])
    sql = c.rows_sql(ENV_, 4)
    assert_includes sql, "FROM events"
    assert_includes sql, "project_id = 7"
    assert_includes sql, "visitor_id != 0"
    assert_includes sql, "event_name = 'o\\'hare'"
    assert_includes sql, "CAST(properties.`plan` AS String) IN ('pro')"
    assert_includes sql, "uniqExact(sipHash64(event_id)) AS n"
    assert_includes sql, "toUInt8(4) AS ci"
    assert_equal "sumIf(r.n, r.ci = 4) >= 3", c.predicate(4)
  end

  test "an event_name match adds an event_type prune ahead of the name filter" do
    c, = build("type" => "event", "event_name" => "checkout", "window" => { "last_days" => 1 })
    sql = c.rows_sql(ENV_, 1)
    assert_match(/event_type = 'custom' AND .*event_name = 'checkout'/, sql)
  end

  test "a screen_view event_name match prunes on the screen_view event_type" do
    c, = build("type" => "event", "event_name" => "screen_view", "window" => { "last_days" => 1 })
    sql = c.rows_sql(ENV_, 1)
    assert_match(/event_type = 'screen_view' AND .*event_name = 'screen_view'/, sql)
  end

  test "an event_type match is unchanged by the event_type prune" do
    c, = build("type" => "event", "event_type" => "install", "window" => { "last_days" => 1 })
    sql = c.rows_sql(ENV_, 1)
    assert_includes sql, "event_type = 'install'"
    assert_equal 1, sql.scan("event_type =").size
  end

  test "an any condition picks no event type, and only leaves message events out" do
    c, = build("type" => "event", "any" => true, "count" => 2, "window" => { "last_days" => 7 },
               "filters" => [{ "field" => "country", "op" => "is", "value" => ["RO"] }])
    sql = c.rows_sql(ENV_, 1)
    assert_includes sql, "FROM events"
    assert_not_includes sql.sub(Grovs::Events::NOT_A_MESSAGE_SQL, ""), "event_type"
  end

  test "properties.<key> always compiles to the JSON property cast, never a top-level column" do
    c, = build("type" => "event", "event_name" => "a", "window" => { "last_days" => 1 },
               "filters" => [{ "field" => "properties.platform", "op" => "is", "value" => ["ios"] },
                             { "field" => "properties.country", "op" => "is", "value" => ["RO"] },
                             { "field" => "properties.user.plan", "op" => "is", "value" => ["pro"] }])
    sql = c.rows_sql(ENV_, 1)
    assert_includes sql, "CAST(properties.`platform` AS String) IN ('ios')"
    assert_includes sql, "CAST(properties.`country` AS String) IN ('RO')"
    assert_includes sql, "CAST(properties.`user.plan` AS String) IN ('pro')"
    assert_not_includes sql, "normalized"
    assert_not_includes sql, "if(platform IN"
    assert_not_includes sql, "sdk_attributes"
  end

  test "negate accepts strict booleans and rejects other truthy strings" do
    c, errors = build("type" => "event", "event_name" => "a", "negate" => "true", "window" => { "last_days" => 1 })
    assert_empty errors
    assert c.negative?

    _, errors2 = build("type" => "event", "event_name" => "a", "negate" => "maybe", "window" => { "last_days" => 1 })
    assert(errors2.any? { |e| e[:path] == "c.negate" })
  end

  test "any is off when false or an invalid string, and errors on an invalid any" do
    c, errors = build("type" => "event", "event_name" => "a", "any" => "false", "window" => { "last_days" => 1 })
    assert_empty errors
    assert_equal "a", c.to_h["event_name"]

    _, errors2 = build("type" => "event", "any" => "banana", "window" => { "last_days" => 1 })
    assert(errors2.any? { |e| e[:path] == "c.any" })
  end

  test "top-level FILTER_COLUMNS resolve to real columns, not properties" do
    c, = build("type" => "event", "event_name" => "a", "window" => { "last_days" => 1 },
               "filters" => [{ "field" => "language", "op" => "is", "value" => ["en"] },
                             { "field" => "platform", "op" => "is", "value" => ["ios"] }])
    sql = c.rows_sql(ENV_, 1)
    assert_includes sql, "language IN ('en')"
    assert_includes sql, "if(platform IN ('ios', 'android'), platform, 'web') IN ('ios')"
    assert_not_includes sql, "properties.`language`"
  end

  test "any-activity with count 1 reads visitor_daily instead of events" do
    c, = build("type" => "event", "any" => true, "window" => { "last_days" => 7 }, "negate" => true)
    assert c.negative?
    sql = c.rows_sql(ENV_, 1)
    assert_includes sql, "FROM visitor_daily"
    assert_includes sql, "event_date >= '2026-09-10'"
  end

  test "a built-in event_type condition with no filters reads visitor_daily with an event_type predicate" do
    c, = build("type" => "event", "event_type" => "app_open", "count" => 3, "window" => { "last_days" => 7 })
    sql = c.rows_sql(ENV_, 1)
    assert_includes sql, "FROM visitor_daily"
    assert_includes sql, "event_type = 'app_open'"
    assert_includes sql, "sum(cnt)"
    assert_not_includes sql, "FROM events"
  end

  test "a built-in event_type condition with a filter still scans events, deduped by hashed event_id" do
    c, = build("type" => "event", "event_type" => "app_open", "count" => 3, "window" => { "last_days" => 7 },
               "filters" => [{ "field" => "country", "op" => "is", "value" => ["RO"] }])
    sql = c.rows_sql(ENV_, 1)
    assert_includes sql, "FROM events"
    assert_includes sql, "uniqExact(sipHash64(event_id)) AS n"
    assert_not_includes sql, "FROM visitor_daily"
  end

  test "an any condition with count above 1 also reads visitor_daily, without an event_type predicate" do
    c, = build("type" => "event", "any" => true, "count" => 2, "window" => { "last_days" => 7 })
    sql = c.rows_sql(ENV_, 1)
    assert_includes sql, "FROM visitor_daily"
    assert_includes sql, "sum(cnt)"
    assert_not_includes sql, "event_type"
  end

  test "the rollup and events paths agree on the rolling window's start date" do
    rollup, = build("type" => "event", "event_type" => "app_open", "count" => 3, "window" => { "last_days" => 7 })
    events, = build("type" => "event", "event_type" => "app_open", "count" => 3, "window" => { "last_days" => 7 },
                    "filters" => [{ "field" => "country", "op" => "is", "value" => ["RO"] }])
    rollup_date = rollup.rows_sql(ENV_, 1)[/event_date >= '(\d{4}-\d{2}-\d{2})'/, 1]
    assert_includes events.rows_sql(ENV_, 1), "created_at >= toDateTime64('#{rollup_date} 00:00:00.000'"
  end

  test "a named (custom) event condition always scans events, even with no filters" do
    c, = build("type" => "event", "event_name" => "checkout", "count" => 3, "window" => { "last_days" => 7 })
    sql = c.rows_sql(ENV_, 1)
    assert_includes sql, "FROM events"
    assert_not_includes sql, "FROM visitor_daily"
  end

  test "any activity and the custom type leave message events out of an events scan; other types need no filter" do
    filter = [{ "field" => "platform", "op" => "is", "value" => ["ios"] }]
    window = { "last_days" => 7 }
    any, = build("type" => "event", "any" => true, "filters" => filter, "window" => window)
    custom, = build("type" => "event", "event_type" => "custom", "filters" => filter, "window" => window)
    install, = build("type" => "event", "event_type" => "install", "filters" => filter, "window" => window)
    named, = build("type" => "event", "event_name" => "push_open", "window" => window)

    [any, custom].each { |c| assert_includes c.rows_sql(ENV_, 1), Grovs::Events::NOT_A_MESSAGE_SQL }
    assert_includes Grovs::Events::NOT_A_MESSAGE_SQL, "event_name IN ('push_open', 'in_app_viewed', 'in_app_clicked', 'in_app_dismissed', 'in_app_answered'"
    [install, named].each { |c| assert_not_includes c.rows_sql(ENV_, 1), "NOT (event_type = 'custom'" }
  end
end
