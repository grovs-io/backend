require "test_helper"

class MergeVisitorClickhouseFoldJobTest < ActiveSupport::TestCase
  test "records the alias, marks both visitors dirty, and repairs acquisition" do
    recorded = nil
    dirty = []
    repaired = nil
    ClickhouseIdentityMapService.stub(:record_merge, ->(pid, from, to) { recorded = [pid, from, to] }) do
      ClickhouseRollupRebuildService.stub(:mark_dirty_for_visitor, ->(pid, vid) { dirty << [pid, vid] }) do
        ClickhouseRollupRebuildService.stub(:repair_acquisition_for_visitor_merge, ->(pid, from, to) { repaired = [pid, from, to] }) do
          MergeVisitorClickhouseFoldJob.new.perform(7, 10, 20)
        end
      end
    end
    assert_equal [7, 10, 20], recorded
    assert_includes dirty, [7, 10] # merged
    assert_includes dirty, [7, 20] # survivor
    assert_equal [7, 10, 20], repaired
  end

  test "busts the MAU cache for both visitors' partitions plus the trailing year" do
    busted = nil
    partitions_by_visitor = { 10 => %w[202401 202402], 20 => %w[202402] }
    ClickhouseIdentityMapService.stub(:record_merge, ->(*) {}) do
      ClickhouseRollupRebuildService.stub(:mark_dirty_for_visitor, ->(_pid, vid) { partitions_by_visitor[vid] }) do
        ClickhouseRollupRebuildService.stub(:repair_acquisition_for_visitor_merge, ->(*) {}) do
          ProjectService.stub(:bust_mau_cache, ->(pid, partitions) { busted = [pid, partitions] }) do
            MergeVisitorClickhouseFoldJob.new.perform(7, 10, 20)
          end
        end
      end
    end
    assert_equal 7, busted[0]
    assert (%w[202401 202402] - busted[1]).empty?, "discovered partitions must be busted"
    assert_includes busted[1], Date.current.strftime("%Y%m"), "trailing-year months busted even if discovery missed them"
    assert_includes busted[1], (Date.current << 12).strftime("%Y%m")
  end

  test "propagates a record_merge failure so Sidekiq retries (no silent alias loss)" do
    ClickhouseIdentityMapService.stub(:record_merge, ->(*) { raise "CH down" }) do
      assert_raises(RuntimeError) do
        MergeVisitorClickhouseFoldJob.new.perform(7, 10, 20)
      end
    end
  end

  test "is a no-op when an id is missing" do
    called = false
    ClickhouseIdentityMapService.stub(:record_merge, ->(*) { called = true }) do
      MergeVisitorClickhouseFoldJob.new.perform(7, nil, 20)
      MergeVisitorClickhouseFoldJob.new.perform(7, 10, nil)
    end
    assert_not called, "missing merged/survivor id must not attempt a fold"
  end
end
