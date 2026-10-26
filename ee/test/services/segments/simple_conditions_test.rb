require "test_helper"

class SegmentsSimpleConditionsTest < ActiveSupport::TestCase
  Env = Struct.new(:project_id, :cutoff_date, :now)
  ENV_ = Env.new(7, Date.new(2026, 1, 1), Time.utc(2026, 9, 17, 12))

  def build(klass, raw)
    errors = []
    [klass.build(raw, path: "c", errors: errors, cutoff_date: ENV_.cutoff_date), errors]
  end

  test "device used-mode scans events for the value inside its window" do
    c, errors = build(Segments::DeviceCondition, "type" => "device", "field" => "app_version", "op" => "is",
                                                  "value" => "3.1", "mode" => "used", "window" => { "last_days" => 30 })
    assert_empty errors
    sql = c.rows_sql(ENV_, 2)
    assert_includes sql, "app_version IN ('3.1')"
    assert_equal "countIf(r.ci = 2) > 0", c.predicate(2)
  end

  test "device current-mode emits no rows of its own and compares the person's latest value" do
    c, = build(Segments::DeviceCondition, "type" => "device", "field" => "platform", "op" => "is", "value" => ["ios"])
    assert c.current?
    assert_nil c.rows_sql(ENV_, 3)
    assert_equal "countIf(r.ci = 3) > 0 AND argMaxIf(r.s, r.n, r.ci = 3) IN ('ios')", c.predicate(3)
  end

  test "used-mode is_not is a person-level negative expressed through the positive form" do
    c, = build(Segments::DeviceCondition, "type" => "device", "field" => "app_version", "op" => "is_not", "value" => ["3.1"],
                                          "mode" => "used", "window" => { "last_days" => 30 })
    assert c.negative?
    assert_includes c.rows_sql(ENV_, 1), "app_version IN ('3.1')"
  end

  test "current-mode is_not needs a known current value, so it is positive" do
    c, = build(Segments::DeviceCondition, "type" => "device", "field" => "platform", "op" => "is_not", "value" => ["ios"])
    assert_not c.negative?
    assert_equal "countIf(r.ci = 1) > 0 AND argMaxIf(r.s, r.n, r.ci = 1) NOT IN ('ios') AND argMaxIf(r.s, r.n, r.ci = 1) != ''", c.predicate(1)
  end

  test "current-mode window is CURRENT_DAYS so a stale retention flags it, but to_h stays canonical" do
    c, = build(Segments::DeviceCondition, "type" => "device", "field" => "platform", "op" => "is", "value" => ["ios"])
    assert_equal({ "last_days" => Segments::DeviceCondition::CURRENT_DAYS }, c.window)
    assert_nil c.to_h["window"]
  end

  test "shared current scan reads platform and country from profiles and the other fields from events" do
    a, = build(Segments::DeviceCondition, "type" => "device", "field" => "platform", "op" => "is", "value" => ["ios"])
    b, = build(Segments::DeviceCondition, "type" => "device", "field" => "app_version", "op" => "is", "value" => ["3.2"])
    c, = build(Segments::DeviceCondition, "type" => "device", "field" => "country", "op" => "is", "value" => ["RO"])
    sql = Segments::DeviceCondition.shared_current_rows_sql(ENV_, [[a, 1], [b, 5], [c, 7]])
    assert_equal 1, sql.scan("FROM user_profiles").size
    assert_equal 1, sql.scan("FROM events").size
    assert_equal 1, sql.scan("UNION ALL").size
    assert_includes sql, "(toUInt8(1), toString(argMax(if(platform IN ('ios', 'android'), platform, 'web'), last_seen)))"
    assert_includes sql, "(toUInt8(7), toString(argMax(country, last_seen)))"
    assert_includes sql, "(toUInt8(5), toString(argMax(app_version, created_at)))"
    assert_includes sql, "last_seen >= toDateTime64("
    assert_equal 2, sql.scan("ARRAY JOIN").size
  end

  test "profile-only current conditions never touch events" do
    a, = build(Segments::DeviceCondition, "type" => "device", "field" => "platform", "op" => "is", "value" => ["ios"])
    sql = Segments::DeviceCondition.shared_current_rows_sql(ENV_, [[a, 1]])
    assert_includes sql, "FROM user_profiles"
    assert_not_includes sql, "FROM events"
    assert_not_includes sql, "UNION ALL"
  end

  test "device rejects unknown fields and a used-mode condition without a window" do
    _, e1 = build(Segments::DeviceCondition, "type" => "device", "field" => "ip", "op" => "is", "value" => "x")
    _, e2 = build(Segments::DeviceCondition, "type" => "device", "field" => "country", "op" => "is", "value" => "RO", "mode" => "used")
    assert_equal 1, e1.size
    assert_equal 1, e2.size
  end

  test "profile reads the latest properties value per visitor without FINAL" do
    c, errors = build(Segments::ProfileCondition, "type" => "profile", "field" => "properties.plan", "op" => "is", "value" => "pro")
    assert_empty errors
    sql = c.rows_sql(ENV_, 6)
    assert_includes sql, "FROM user_profiles"
    assert_not_includes sql, "FINAL"
    assert_includes sql, "argMax(ifNull(CAST(properties.`plan` AS Nullable(String)), ''), last_seen)"
    assert_includes sql, "val IN ('pro')"
  end

  test "profile scan excludes the vmap no-row sentinel visitor" do
    c, = build(Segments::ProfileCondition, "type" => "profile", "field" => "properties.plan", "op" => "is", "value" => "pro")
    assert_includes c.rows_sql(ENV_, 1), "visitor_id != 0"
  end

  test "profile is_not_set is negative and its positive form is 'is set'" do
    c, = build(Segments::ProfileCondition, "type" => "profile", "field" => "properties.plan", "op" => "is_not_set")
    assert c.negative?
    assert_includes c.rows_sql(ENV_, 1), "val != ''"
  end

  test "profile rejects an invalid property key" do
    _, errors = build(Segments::ProfileCondition, "type" => "profile", "field" => "properties.a b", "op" => "is_set")
    assert_equal 1, errors.size
  end

  test "first_seen compares the person's earliest visitor minimum" do
    c, errors = build(Segments::FirstSeenCondition, "type" => "first_seen", "op" => "gte", "value" => "2026-06-01")
    assert_empty errors
    assert_includes c.rows_sql(ENV_, 2), "minMerge(first_seen_state)"
    assert_equal "countIf(r.ci = 2) > 0 AND minIf(r.n, r.ci = 2) >= #{Time.utc(2026, 6, 1).to_i}", c.predicate(2)
    late, = build(Segments::FirstSeenCondition, "type" => "first_seen", "op" => "lte", "value" => "2026-06-01")
    assert_includes late.predicate(2), "<= #{Time.utc(2026, 6, 2).to_i - 1}"
  end

  test "first_seen rejects a bad op or date" do
    _, e1 = build(Segments::FirstSeenCondition, "type" => "first_seen", "op" => "is", "value" => "2026-06-01")
    _, e2 = build(Segments::FirstSeenCondition, "type" => "first_seen", "op" => "gte", "value" => "June")
    assert_equal 1, e1.size
    assert_equal 1, e2.size
  end
end
