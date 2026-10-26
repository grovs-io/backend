require "test_helper"

class SegmentsCatalogueTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  fixtures :instances, :projects

  setup do
    @project = projects(:one)
  end

  test "every definition type appears exactly once in conditions" do
    catalogue = Segments::Catalogue.for(@project)
    types = catalogue[:conditions].map { |c| c[:type] }
    assert_equal Segments::Definition::TYPES.keys.sort, types.sort
    assert_equal types.size, types.uniq.size
  end

  test "purchase.enabled follows the instance's revenue_collection_enabled flag" do
    @project.instance.update!(revenue_collection_enabled: false)
    purchase = Segments::Catalogue.for(@project)[:conditions].find { |c| c[:type] == "purchase" }
    assert_equal false, purchase[:enabled]

    @project.instance.update!(revenue_collection_enabled: true)
    purchase = Segments::Catalogue.for(@project)[:conditions].find { |c| c[:type] == "purchase" }
    assert_equal true, purchase[:enabled]
  end

  test "property_keys is empty when ClickHouse reads are off" do
    Clickhouse.stub(:read_enabled?, false) do
      profile = Segments::Catalogue.for(@project)[:conditions].find { |c| c[:type] == "profile" }
      assert_equal [], profile[:property_keys]
    end
  end

  test "property_keys is empty when the query raises" do
    Clickhouse.stub(:read_enabled?, true) do
      Segments::Runner.stub(:read, ->(*) { raise Analytics::QueryTooHeavy }) do
        profile = Segments::Catalogue.for(@project)[:conditions].find { |c| c[:type] == "profile" }
        assert_equal [], profile[:property_keys]
      end
    end
  end

  test "property_keys discovers keys from a seeded profile" do
    skip_unless_clickhouse!
    insert_ch_user_profiles(project_id: @project.id, visitor_id: 1, properties: { "plan" => "pro" },
                             first_seen: "2026-09-01 00:00:00.000", last_seen: "2026-09-01 00:00:00.000")
    profile = Segments::Catalogue.for(@project)[:conditions].find { |c| c[:type] == "profile" }
    assert_equal ["plan"], profile[:property_keys]
  end

  test "the discovery query samples the newest visitors by visitor_id, not last_seen" do
    captured = nil
    Clickhouse.stub(:read_enabled?, true) do
      Segments::Runner.stub(:read, lambda { |sql|
        captured = sql
        []
      }) do
        Segments::Catalogue.send(:discover_profile_property_keys, @project.id)
      end
    end
    assert_includes captured.squish, "ORDER BY visitor_id DESC LIMIT 50000"
  end

  test "the sample bound is applied before arrayJoin, so a key beyond the sample is excluded" do
    skip_unless_clickhouse!
    insert_ch_user_profiles([
      { project_id: @project.id, visitor_id: 1, properties: { "old_key" => "x" },
        first_seen: "2026-09-01 00:00:00.000", last_seen: "2026-09-01 00:00:00.000" },
      { project_id: @project.id, visitor_id: 2, properties: { "new_key" => "y" },
        first_seen: "2026-09-02 00:00:00.000", last_seen: "2026-09-02 00:00:00.000" }
    ])
    keys = Segments::Catalogue.send(:discover_profile_property_keys, @project.id, sample: 1)
    assert_equal ["new_key"], keys
  end
end
