require "test_helper"
require_relative "../../support/in_app_shared_cases"
require_relative "../../support/in_app_reference_engine"

class InAppReferenceEngineTest < ActiveSupport::TestCase
  VALUES = [nil, "text", 5, 1.5, true, [], [nil], ["x"], {}, { "a" => 1 }].freeze
  EVENTS = [{ "type" => "app_open" }, { "type" => "screen_view", "name" => "Cart" },
            { "type" => "event", "name" => "cart_viewed", "properties" => { "v" => 1 } }].freeze

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

  test "no value in any position of a definition makes the engine raise" do
    kase = InAppSharedCases.expanded.find { |k| k["name"] == "personalization fills user and event fields and uses fallbacks" }
    campaign = kase["campaigns"].first
    paths(campaign).product(VALUES).each do |trail, value|
      engine = InAppReferenceEngine.new(kase.merge("campaigns" => [replaced(campaign, trail, value), nil, 5]))
      EVENTS.each { |event| assert_kind_of Hash, engine.track(event, "2026-10-01T10:00:00Z") }
    end
  end

  InAppSharedCases.expanded.each do |kase|
    test kase["name"] do
      engine = InAppReferenceEngine.new(kase)
      kase["steps"].each_with_index do |step, index|
        next engine.start_session if step["session_start"]
        next engine.sync(step["sync"]) if step["sync"]
        next engine.answer(step["answer"]) if step["answer"]

        result = engine.track(step["event"], step["at"])
        step["expect"].each do |key, wanted|
          label = "step #{index + 1}, #{key}"
          wanted.nil? ? assert_nil(result[key], label) : assert_equal(wanted, result[key], label)
        end
      end
    end
  end
end
