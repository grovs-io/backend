require "test_helper"
require "json-schema"
require_relative "../../support/in_app_shared_cases"

class InAppSharedCasesTest < ActiveSupport::TestCase
  test "the cases file matches its schema" do
    assert_empty JSON::Validator.fully_validate(InAppSharedCases.cases_schema, InAppSharedCases.file)
  end

  test "case names are unique" do
    names = InAppSharedCases.file.fetch("cases").pluck("name")
    assert_equal names.uniq, names
  end

  test "campaign ids are unique within a case" do
    InAppSharedCases.expanded.each do |kase|
      ids = kase["campaigns"].pluck("id")
      assert_equal ids.uniq, ids, kase["name"]
    end
  end

  test "every campaign matches the definition schema unless the case marks it off schema" do
    schema = InAppSharedCases.definition_schema
    InAppSharedCases.expanded.each do |kase|
      kase["campaigns"].each do |campaign|
        errors = JSON::Validator.fully_validate(schema, campaign)
        label = "#{kase['name']} / #{campaign['id']}"
        kase["off_schema"].include?(campaign["id"]) ? assert_not_empty(errors, label) : assert_empty(errors, label)
      end
    end
  end

  test "every expected reason names a campaign in the case" do
    InAppSharedCases.expanded.each do |kase|
      ids = kase["campaigns"].pluck("id")
      kase["steps"].select { |s| s["expect"] }.each do |step|
        named = step["expect"]["reasons"].keys + [step["expect"]["show"]].compact
        assert_equal ids.sort, named.sort, "#{kase['name']} at #{step['at']}"
      end
    end
  end

  test "every reason in the schema is exercised by a case" do
    known = InAppSharedCases.cases_schema.dig("definitions", "expect", "properties", "reasons", "additionalProperties", "enum")
    used = InAppSharedCases.expanded.flat_map { |k| k["steps"] }.select { |s| s["expect"] }.flat_map { |s| s["expect"]["reasons"].values }
    assert_empty known - used
  end

  test "html_parsing covers both a valid definition and the ways one is unsupported" do
    outcomes = InAppSharedCases.file.fetch("html_parsing").pluck("expect")
    assert_includes outcomes, "valid"
    assert_includes outcomes, "unsupported"
  end

  test "link_rule has at least 30 cases and covers both outcomes" do
    cases = InAppSharedCases.file.fetch("link_rule")
    assert_operator cases.length, :>=, 30
    assert_includes cases.pluck("expect"), "allowed"
    assert_includes cases.pluck("expect"), "refused"
  end

  test "merge replaces arrays and scalars and merges objects" do
    merged = InAppSharedCases.merge({ "a" => { "x" => 1, "y" => [1, 2] }, "b" => 1 }, { "a" => { "y" => [3] }, "b" => 2 })
    assert_equal({ "a" => { "x" => 1, "y" => [3] }, "b" => 2 }, merged)
  end
end
