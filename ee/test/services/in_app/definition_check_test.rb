require "test_helper"
require "json-schema"
require_relative "../../support/in_app_shared_cases"
require_relative "../../support/in_app_definition_check"

class InAppDefinitionCheckTest < ActiveSupport::TestCase
  SCHEMA = InAppSharedCases.definition_schema

  def base = InAppSharedCases.file.fetch("base_campaign")
  def with(changes) = InAppSharedCases.merge(base, changes)
  def on_schema?(definition) = JSON::Validator.fully_validate(SCHEMA, definition).empty?

  MALFORMED = {
    "a platform condition with an operator for text" => { "conditions" => [{ "type" => "platform", "op" => "contains", "value" => "i" }] },
    "a language condition with no value" => { "conditions" => [{ "type" => "language", "op" => "eq" }] },
    "a version condition with a number" => { "conditions" => [{ "type" => "app_version", "op" => "gt", "value" => 2 }] },
    "a version range with one end" => { "conditions" => [{ "type" => "os_version", "op" => "between", "value" => ["16"] }] },
    "a version condition that asks whether it is set" => { "conditions" => [{ "type" => "app_version", "op" => "is_set" }] },
    "a user attribute with no key" => { "conditions" => [{ "type" => "user_attribute", "op" => "is_set" }] },
    "a user attribute compared with a list" => { "conditions" => [{ "type" => "user_attribute", "key" => "plan", "op" => "eq", "value" => %w[a b] }] },
    "an event count with no name" => { "conditions" => [{ "type" => "event_count", "op" => "gt", "value" => 1 }] },
    "an event count compared with a word" => { "conditions" => [{ "type" => "event_count", "name" => "a", "op" => "gt", "value" => "many" }] },
    "a first seen day count as text" => { "conditions" => [{ "type" => "first_seen", "op" => "within_days", "value" => "7" }] },
    "a first seen day count of zero" => { "conditions" => [{ "type" => "first_seen", "op" => "within_days", "value" => 0 }] },
    "a first seen date without a time" => { "conditions" => [{ "type" => "first_seen", "op" => "before", "value" => "2026-09-01" }] },
    "a first seen condition with an operator for numbers" => { "conditions" => [{ "type" => "first_seen", "op" => "eq", "value" => 1 }] },
    "an event trigger with no name" => { "triggers" => [{ "type" => "event" }] },
    "a screen view trigger with filters" => { "triggers" => [{ "type" => "screen_view", "filters" => [] }] },
    "an app open trigger with a name" => { "triggers" => [{ "type" => "app_open", "name" => "launch" }] },
    "a filter with no value" => { "triggers" => [{ "type" => "event", "name" => "a", "filters" => [{ "field" => "v", "op" => "eq" }] }] },
    "a range filter with a single number" => {
      "triggers" => [{ "type" => "event", "name" => "a", "filters" => [{ "field" => "v", "op" => "between", "value" => 5 }] }]
    },
    "a link action with no link" => { "content" => { "tap_action" => { "type" => "open_url" } } },
    "a key-value action with no payload" => { "content" => { "tap_action" => { "type" => "key_value" } } },
    "hours with a start and no end" => { "schedule" => { "from" => "09:00" } },
    "hours with an end and no start" => { "schedule" => { "to" => "21:00" } },
    "an empty list of days" => { "schedule" => { "days" => [] } },
    "a month of 13" => { "created_at" => "2026-13-01T00:00:00Z" },
    "an hour of 25" => { "schedule" => { "start_at" => "2026-09-01T25:00:00Z" } },
    "a lowercase z" => { "created_at" => "2026-09-01T00:00:00z" },
    "four fractional digits" => { "created_at" => "2026-09-01T00:00:00.1234Z" },
    "a filter that is a number" => { "triggers" => [{ "type" => "event", "name" => "a", "filters" => [5] }] },
    "a condition that is text" => { "conditions" => ["ios"] },
    "a button that is null" => { "content" => { "buttons" => [nil] } }
  }.freeze

  MALFORMED.each do |name, changes|
    test "schema and engine both refuse #{name}" do
      assert_not on_schema?(with(changes)), "the schema accepted it"
      assert_not InAppDefinitionCheck.well_formed?(with(changes)), "the engine check accepted it"
    end
  end

  test "every case campaign the schema accepts is one the engine can read" do
    InAppSharedCases.expanded.each do |kase|
      kase["campaigns"].select { |c| on_schema?(c) }.each do |campaign|
        assert InAppDefinitionCheck.well_formed?(campaign), "#{kase['name']} / #{campaign['id']}"
      end
    end
  end

  test "the engine refuses a date that is not on the calendar" do
    assert_not InAppDefinitionCheck.well_formed?(with("created_at" => "2026-02-30T00:00:00Z"))
    assert InAppDefinitionCheck.well_formed?(with("created_at" => "2028-02-29T00:00:00Z"))
  end

  test "a number with no fractional part is an integer" do
    assert InAppDefinitionCheck.well_formed?(with("priority" => 5.0, "caps" => { "day" => 2.0 }))
    assert_not InAppDefinitionCheck.well_formed?(with("priority" => 5.5))
  end

  VALUES = [nil, "text", "", 5, -1, 1.5, true, [], [1], ["x"], [nil], {}, { "a" => 1 }].freeze

  def paths(node, trail = [])
    inner = case node
            when Hash then node.flat_map { |key, child| paths(child, trail + [key]) }
            when Array then node.each_with_index.flat_map { |child, index| paths(child, trail + [index]) }
            else []
            end
    trail.empty? ? inner : [trail] + inner
  end

  def replaced(node, trail, value)
    copy = Marshal.load(Marshal.dump(node))
    *lead, last = trail
    lead.reduce(copy) { |inner, key| inner[key] }[last] = value
    copy
  end

  test "no value in any position makes the check raise" do
    rich = InAppSharedCases.expanded.flat_map { |k| k["campaigns"] }.select { |c| on_schema?(c) }
    rich.first(40).each do |campaign|
      paths(campaign).each do |trail|
        VALUES.each { |value| assert_includes [true, false], InAppDefinitionCheck.well_formed?(replaced(campaign, trail, value)) }
      end
    end
  end

  test "unknown fields do not stop the engine reading a definition" do
    assert InAppDefinitionCheck.well_formed?(with("future" => { "a" => 1 }, "content" => { "subtitle" => "x" }, "caps" => { "month" => 1 }))
  end

  test "a definition that is not an object is refused without raising" do
    [nil, [], "text", 5, { "content" => "text" }, { "triggers" => "all" }].each do |broken|
      assert_not InAppDefinitionCheck.well_formed?(broken.is_a?(Hash) ? with(broken) : broken)
    end
  end
end
