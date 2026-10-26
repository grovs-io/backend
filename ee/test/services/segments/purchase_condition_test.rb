require "test_helper"

class SegmentsPurchaseConditionTest < ActiveSupport::TestCase
  Env = Struct.new(:project_id, :cutoff_date, :now, :segment_id, :list_generation)
  ENV_ = Env.new(7, Date.new(2025, 1, 1), Time.utc(2026, 9, 17, 12), nil, nil)

  def build(raw)
    errors = []
    [Segments::PurchaseCondition.build({ "type" => "purchase", "window" => { "last_days" => 90 } }.merge(raw), path: "c", errors: errors,
                                                                                                             cutoff_date: ENV_.cutoff_date), errors]
  end

  test "counts eligible transactions per visitor and carries spend in s" do
    c, errors = build("product_id" => ["pro_yearly"], "count" => 2, "min_total_usd_cents" => 5000)
    assert_empty errors
    sql = c.rows_sql(ENV_, 3)
    assert_includes sql, "FROM purchase_events FINAL"
    assert_includes sql, "GROUP BY #{Segments::PurchaseCondition::TRANSACTION_SQL}"
    assert_includes sql, "buys > 0 AND refunds <= reversals"
    assert_includes sql, "product_id IN ('pro_yearly')"
    assert_includes sql, "project_id = 7"
    assert_equal "sumIf(r.n, r.ci = 3) >= 2 AND sumIf(toUInt64OrZero(r.s), r.ci = 3) >= 5000", c.predicate(3)
  end

  test "history is cut a day before the window start, ahead of the per-transaction grouping" do
    c, = build("window" => { "from" => "2026-09-01", "to" => "2026-09-05" })
    inner = c.rows_sql(ENV_, 1)[/FROM purchase_events FINAL WHERE (.*?) GROUP BY /, 1]
    assert_includes inner, "purchase_date >= toDateTime64('2026-08-31 00:00:00.000', 3, 'UTC')"
    assert_includes inner, "created_at >= toDateTime64('2026-08-31 00:00:00.000', 3, 'UTC')"
    assert_not_includes inner, "purchase_date <="
  end

  test "defaults, negation and validation" do
    c, = build("negate" => "true")
    assert c.negative?
    assert_equal 1, c.to_h["count"]
    _, e1 = build("purchase_type" => ["lease"])
    _, e2 = build("count" => 0)
    _, e3 = build("min_total_usd_cents" => -1)
    _, e4 = build("window" => { "last_days" => 366 })
    [e1, e2, e3, e4].each { |e| assert_equal 1, e.size }
  end

  test "round-trips through its canonical form" do
    c, = build("store_source" => %w[google apple], "count" => "3")
    again, errors = build(c.to_h.except("type"))
    assert_empty errors
    assert_equal c.to_h, again.to_h
  end
end
