require "test_helper"

class SegmentTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :users

  FakeDefinition = Struct.new(:errors, :canonical, :digest) do
    def valid? = errors.empty?
    def uses?(_type) = false
  end

  PURCHASE_DEFINITION = { "version" => 1, "operator" => "and", "groups" => [
    { "operator" => "and", "conditions" => [{ "type" => "purchase", "window" => { "last_days" => 30 } }] }
  ] }.freeze

  def with_definition(fake, &)
    Segments::Definition.stub(:parse, fake, &)
  end

  test "saves the canonical definition and its hash" do
    fake = FakeDefinition.new([], { "version" => 1 }, "abc123")
    with_definition(fake) do
      s = Segment.create!(project: projects(:one), name: "Buyers", definition: { "anything" => true })
      assert_equal({ "version" => 1 }, s.definition)
      assert_equal "abc123", s.definition_hash
    end
  end

  test "an invalid definition blocks the save and reports the condition path" do
    fake = FakeDefinition.new([{ path: "groups[0].conditions[1]", message: "unknown type" }], {}, "")
    with_definition(fake) do
      s = Segment.new(project: projects(:one), name: "Bad", definition: {})
      assert_not s.valid?
      assert_includes s.errors[:definition], "groups[0].conditions[1]: unknown type"
    end
  end

  test "name is required" do
    fake = FakeDefinition.new([], {}, "h")
    with_definition(fake) do
      assert_not Segment.new(project: projects(:one), definition: {}).valid?
    end
  end

  test "active excludes archived segments" do
    fake = FakeDefinition.new([], {}, "h")
    with_definition(fake) do
      live = Segment.create!(project: projects(:one), name: "a", definition: {})
      Segment.create!(project: projects(:one), name: "b", definition: {}, archived: true)
      assert_equal [live.id], Segment.active.pluck(:id)
    end
  end

  test "an aged fixed-window definition can still be archived and renamed, and re-parses as incomplete" do
    from = Date.current - 20
    to = Date.current - 10
    raw = { "version" => 1, "operator" => "and", "groups" => [
      { "operator" => "and", "conditions" => [
        { "type" => "event", "event_name" => "checkout", "window" => { "from" => from.iso8601, "to" => to.iso8601 } }
      ] }
    ] }
    segment = Segment.create!(project: projects(:one), name: "Aged", definition: raw)

    later_cutoff = Date.current - 15
    fake_policy = Struct.new(:queryable_cutoff_date).new(later_cutoff)
    Analytics::RetentionPolicy.stub(:for, fake_policy) do
      assert segment.update!(archived: true)
      assert segment.update!(name: "renamed")
      assert segment.reload.parsed_definition.valid?

      compiler = Segments::Compiler.new(segment.parsed_definition, project_id: segment.project_id, cutoff_date: later_cutoff)
      assert compiler.incomplete?

      segment.definition = raw
      assert_not segment.save
      assert_match(/retention/, segment.errors[:definition].join)
    end
  end

  test "a real definition saves, hashes, and re-parses from the stored canonical" do
    raw = { "version" => 1, "operator" => "and", "groups" => [
      { "operator" => "and", "conditions" => [
        { "type" => "event", "event_name" => "checkout", "window" => { "last_days" => 30 } }
      ] }
    ] }
    segment = Segment.create!(project: projects(:one), name: "Buyers", definition: raw)
    assert_match(/\A[0-9a-f]{64}\z/, segment.definition_hash)
    assert segment.reload.parsed_definition.valid?
  end

  test "a purchase condition is blocked when revenue collection is disabled on the instance" do
    assert_not instances(:two).revenue_collection_enabled
    segment = Segment.new(project: projects(:two), name: "Buyers", definition: PURCHASE_DEFINITION)
    assert_not segment.valid?
    assert_includes segment.errors[:definition].join, "revenue collection"
  end

  test "a purchase condition saves when revenue collection is enabled on the instance" do
    assert instances(:one).revenue_collection_enabled
    segment = Segment.create!(project: projects(:one), name: "Buyers", definition: PURCHASE_DEFINITION)
    assert segment.reload.parsed_definition.valid?
  end
end
