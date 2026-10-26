require "test_helper"

class ExperimentsSplitTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  test "the bucket is the same in Ruby and ClickHouse, and spreads evenly" do
    skip_unless_clickhouse!
    ids = (1..500).to_a + [10**9, 2**40]
    sql = "SELECT visitor_id, #{Experiments::Bucket.sql('{salt:String}')} AS b FROM (SELECT arrayJoin([#{ids.join(',')}]) AS visitor_id)"
    rows = Clickhouse.with { |c| c.select_all(ClickHouse::Client::Query.new(raw_query: sql, placeholders: { salt: "OQGFkZ" })) }
    got = rows.to_h { |r| [r["visitor_id"].to_i, r["b"].to_i] }
    ids.each { |id| assert_equal Experiments::Bucket.of("OQGFkZ", id), got[id], "visitor #{id}" }

    share = (1..10_000).map { |id| Experiments::Bucket.of("salt", id) }.tally.values
    assert_equal 100, share.size
    assert share.all? { |n| n.between?(60, 140) }, share.minmax.inspect
  end

  test "the control comes first and the variants share the rest equally" do
    groups = (0..99).map { |b| Experiments::Split.group(b, control: 10, variants: 3) }
    assert_equal({ "control" => 10, "a" => 30, "b" => 30, "c" => 30 }, groups.tally)
    assert_equal %w[control] * 10 + %w[a] * 30 + %w[b] * 30 + %w[c] * 30, groups
    assert_equal({ "a" => 100 }, (0..99).map { |b| Experiments::Split.group(b, control: 0, variants: 1) }.tally)
    assert_equal({ "control" => 50, "a" => 25, "b" => 25 }, (0..99).map { |b| Experiments::Split.group(b, control: 50, variants: 2) }.tally)
  end

  test "the split reads the same in ClickHouse" do
    skip_unless_clickhouse!
    sql = "SELECT b, #{Experiments::Split.sql('b', control: 10, variants: 3)} AS g FROM (SELECT arrayJoin(range(100)) AS b)"
    rows = Clickhouse.with { |c| c.select_all(ClickHouse::Client::Query.new(raw_query: sql)) }
    rows.each { |r| assert_equal Experiments::Split.group(r["b"].to_i, control: 10, variants: 3), r["g"] }
  end
end
