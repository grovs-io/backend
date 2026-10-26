require "test_helper"

class SegmentsDefinitionTest < ActiveSupport::TestCase
  CUTOFF = Date.new(2026, 1, 1)

  def event(name, extra = {})
    { "type" => "event", "event_name" => name, "window" => { "last_days" => 30 } }.merge(extra)
  end

  def tree(groups, operator: "or")
    { "version" => 1, "operator" => operator, "groups" => groups }
  end

  def parse(raw) = Segments::Definition.parse(raw, cutoff_date: CUTOFF)

  test "parses a two-level tree" do
    d = parse(tree([{ "operator" => "and", "conditions" => [event("a"), event("b")] }]))
    assert d.valid?, d.errors.inspect
    assert_equal "or", d.operator
    assert_equal 2, d.groups.first.conditions.size
  end

  test "accepts ActionController-style params and symbol keys" do
    raw = ActionController::Parameters.new(version: 1, operator: "and", groups: [{ operator: "or", conditions: [event("a")] }])
    assert parse(raw).valid?
  end

  test "rejects a wrong version, bad operators, unknown types and nested groups" do
    assert_not parse(tree([], operator: "and").merge("version" => 2)).valid?
    assert_not parse(tree([{ "operator" => "xor", "conditions" => [event("a")] }])).valid?
    assert_not parse(tree([{ "operator" => "and", "conditions" => [{ "type" => "astrology" }] }])).valid?
    nested = parse(tree([{ "operator" => "and", "conditions" => [{ "operator" => "and", "conditions" => [event("a")] }] }]))
    assert_equal "groups[0].conditions[0]", nested.errors.first[:path]
  end

  test "enforces group and condition limits" do
    assert_not parse(tree([])).valid?
    too_many_groups = Array.new(6) { { "operator" => "and", "conditions" => [event("a")] } }
    assert_not parse(tree(too_many_groups)).valid?
    too_many_conditions = [{ "operator" => "and", "conditions" => Array.new(11) { event("a") } }]
    assert_not parse(tree(too_many_conditions)).valid?
  end

  test "a negative condition needs an and-group with a positive sibling" do
    lonely = parse(tree([{ "operator" => "and", "conditions" => [event("a", "negate" => true)] }]))
    in_or = parse(tree([{ "operator" => "or", "conditions" => [event("a"), event("b", "negate" => true)] }]))
    fine = parse(tree([{ "operator" => "and", "conditions" => [event("a"), event("b", "negate" => true)] }]))
    assert_match(/positive/, lonely.errors.first[:message])
    assert_match(/and/, in_or.errors.first[:message])
    assert fine.valid?
  end

  test "version must be a strict integer, never raising on a hostile shape" do
    [true, [1], { "a" => 1 }, "1junk", 1.9].each do |bad|
      d = parse(tree([{ "operator" => "and", "conditions" => [event("a")] }]).merge("version" => bad))
      assert_not d.valid?
      assert_equal "version must be 1", d.errors.first[:message]
    end
    ["1", 1].each do |ok|
      d = parse(tree([{ "operator" => "and", "conditions" => [event("a")] }]).merge("version" => ok))
      assert d.valid?, d.errors.inspect
    end
  end

  test "digest ignores key order and value order" do
    a = parse(tree([{ "operator" => "and", "conditions" => [
                 { "type" => "device", "field" => "platform", "op" => "is", "value" => %w[ios android] }
               ] }]))
    b = parse(tree([{ "conditions" => [
                 { "value" => %w[android ios], "op" => "is", "field" => "platform", "type" => "device" }
               ], "operator" => "and" }]))
    assert_equal a.digest, b.digest
    assert_equal 64, a.digest.size
  end

  test "canonical round-trips through parse unchanged" do
    d = parse(tree([{ "operator" => "and", "conditions" => [event("a", "count" => "3")] }]))
    assert_equal d.canonical, parse(d.canonical).canonical
  end

  test "hostile shapes are reported, never raised" do
    filters_hash = tree([{ "operator" => "and", "conditions" => [event("a", "filters" => { "x" => "y" })] }])
    filters_bad_entry = tree([{ "operator" => "and", "conditions" => [event("a", "filters" => ["not-a-hash"])] }])
    device_value_hash = tree([{ "operator" => "and", "conditions" => [
      { "type" => "device", "field" => "platform", "op" => "is", "value" => { "a" => "b" } }
    ] }])
    device_value_nested = tree([{ "operator" => "and", "conditions" => [
      { "type" => "device", "field" => "platform", "op" => "is", "value" => [["nested"]] }
    ] }])
    groups_hash = { "version" => 1, "operator" => "and", "groups" => { "operator" => "and", "conditions" => [event("a")] } }
    conditions_string = tree([{ "operator" => "and", "conditions" => "nope" }])

    [filters_hash, filters_bad_entry, device_value_hash, device_value_nested,
     groups_hash, conditions_string, nil, [1, 2, 3]].each do |raw|
      d = parse(raw)
      assert_not d.valid?
    end
  end
end
