require "test_helper"

class SegmentsAcquisitionConditionTest < ActiveSupport::TestCase
  Env = Struct.new(:project_id, :cutoff_date, :now, :segment_id, :list_generation)
  ENV_ = Env.new(7, Date.new(2025, 1, 1), Time.utc(2026, 9, 17, 12), nil, nil)

  def build(raw)
    errors = []
    [Segments::AcquisitionCondition.build({ "type" => "acquisition" }.merge(raw), path: "c", errors: errors, cutoff_date: ENV_.cutoff_date), errors]
  end

  test "campaign ids scan install events only, over a default 365-day window" do
    c, errors = build("field" => "campaign_id", "op" => "is", "value" => [12, "15"])
    assert_empty errors
    assert_equal({ "last_days" => 365 }, c.window)
    sql = c.rows_sql(ENV_, 4)
    assert_includes sql, "event_type IN ('install', 'reinstall')"
    assert_includes sql, "campaign_id IN (12, 15)"
    assert_includes sql, "project_id = 7"
    assert_equal "countIf(r.ci = 4) > 0", c.predicate(4)
  end

  test "string fields use quoting and is_not is a person-level negative" do
    c, = build("field" => "tracking_source", "op" => "is_not", "value" => "o'fb")
    assert c.negative?
    assert_includes c.rows_sql(ENV_, 1), "tracking_source IN ('o\\'fb')"
  end

  test "rejects unknown fields, non-integer ids, contains on ids and windows over the cap" do
    _, e1 = build("field" => "ip", "op" => "is", "value" => "x")
    _, e2 = build("field" => "link_id", "op" => "is", "value" => ["abc"])
    _, e3 = build("field" => "link_id", "op" => "contains", "value" => [1])
    _, e4 = build("field" => "campaign_id", "op" => "is", "value" => [1], "window" => { "last_days" => 366 })
    [e1, e2, e3, e4].each { |e| assert_equal 1, e.size }
  end

  test "round-trips through its canonical form" do
    c, = build("field" => "link_id", "op" => "is", "value" => [9, 3])
    again, errors = build(c.to_h.except("type"))
    assert_empty errors
    assert_equal c.to_h, again.to_h
    assert_equal [3, 9], c.to_h["value"]
  end

  test "a near-retention cutoff clamps the default window instead of always being incomplete" do
    errors = []
    cutoff = Date.current - 10
    c = Segments::AcquisitionCondition.build({ "type" => "acquisition", "field" => "campaign_id", "op" => "is", "value" => [1] },
                                              path: "c", errors: errors, cutoff_date: cutoff)
    assert_empty errors
    assert_equal({ "last_days" => 10 }, c.window)
  end

  test "an explicit window is not clamped by a near retention cutoff" do
    errors = []
    cutoff = Date.current - 10
    c = Segments::AcquisitionCondition.build({ "type" => "acquisition", "field" => "campaign_id", "op" => "is", "value" => [1],
                                                "window" => { "last_days" => 30 } },
                                              path: "c", errors: errors, cutoff_date: cutoff)
    assert_empty errors
    assert_equal({ "last_days" => 30 }, c.window)
  end
end
