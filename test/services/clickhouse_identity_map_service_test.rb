# frozen_string_literal: true

require "test_helper"

# CH-gated: the visitor identity map records merged->survivor aliases flat
# (path-compressed) and idempotently.
class ClickhouseIdentityMapServiceTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  PROJECT_ID = 8801

  setup { skip_unless_clickhouse! }

  test "records a single merge alias" do
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, 10, 20)

    assert_equal({ 10 => 20 }, map_for(PROJECT_ID))
  end

  test "recording the same merge twice is idempotent (one flat row)" do
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, 10, 20)
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, 10, 20)

    assert_equal({ 10 => 20 }, map_for(PROJECT_ID))
  end

  test "chain A->B then B->C path-compresses A to point at C" do
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, 1, 2) # A->B
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, 2, 3) # B->C

    # Both A and B must resolve to the FINAL survivor C — no A->B left.
    assert_equal({ 1 => 3, 2 => 3 }, map_for(PROJECT_ID))
  end

  test "merging into an already-merged-away survivor resolves to the final survivor" do
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, 2, 3) # B->C (C is survivor)
    # Now merge A into B, but B was already merged into C: A must end at C.
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, 1, 2)

    assert_equal({ 1 => 3, 2 => 3 }, map_for(PROJECT_ID))
  end

  test "maps are isolated per project" do
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, 10, 20)
    ClickhouseIdentityMapService.record_merge(PROJECT_ID + 1, 10, 99)

    assert_equal({ 10 => 20 }, map_for(PROJECT_ID))
    assert_equal({ 10 => 99 }, map_for(PROJECT_ID + 1))
  end

  test "resolve_many maps each id to its survivor, identity for unmapped" do
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, 10, 20)

    assert_equal({ 10 => 20, 20 => 20, 30 => 30 },
                 ClickhouseIdentityMapService.resolve_many(PROJECT_ID, [10, 20, 30]))
  end

  test "resolve_many is project-scoped" do
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, 10, 20)

    assert_equal({ 10 => 10 }, ClickhouseIdentityMapService.resolve_many(PROJECT_ID + 1, [10]))
  end

  test "resolve_many on empty input returns empty hash" do
    assert_equal({}, ClickhouseIdentityMapService.resolve_many(PROJECT_ID, []))
  end

  private

  # Returns {from => to} for a project, reading the deduped (FINAL) latest rows.
  def map_for(project_id)
    rows = Clickhouse.with do |conn|
      conn.select_all(
        "SELECT from_visitor_id, to_visitor_id FROM visitor_identity_map FINAL " \
        "WHERE project_id = #{Integer(project_id)} ORDER BY from_visitor_id"
      )
    end
    rows.to_h { |r| [r["from_visitor_id"].to_i, r["to_visitor_id"].to_i] }
  end
end
