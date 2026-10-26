require "test_helper"
require "sidekiq/testing"

class SegmentSizeSnapshotJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  DEFINITION = { "version" => 1, "operator" => "or", "groups" => [{ "operator" => "and", "conditions" => [
    { "type" => "event", "any" => true, "window" => { "last_days" => 30 } }
  ] }] }.freeze

  setup { @segment = Segment.create!(project: projects(:one), name: "Active", definition: DEFINITION) }

  test "writes one row per day and overwrites it on a re-run" do
    Segments.stub(:estimate, { persons: 10, devices: 12, approximate: false, incomplete: false }) { SegmentSizeSnapshotJob.new.perform(@segment.id) }
    Segments.stub(:estimate, { persons: 11, devices: 12, approximate: false, incomplete: true }) { SegmentSizeSnapshotJob.new.perform(@segment.id) }
    rows = SegmentSizeSnapshot.where(segment_id: @segment.id)
    assert_equal 1, rows.count
    assert_equal [11, 12, true, @segment.definition_hash], rows.first.values_at(:persons, :devices, :incomplete, :definition_hash)
  end

  test "a heavy or unavailable segment is skipped quietly, an archived one ignored" do
    [Analytics::QueryTooHeavy, Clickhouse::Unavailable.new("segments")].each do |error|
      Segments.stub(:estimate, ->(*) { raise error }) { assert_nothing_raised { SegmentSizeSnapshotJob.new.perform(@segment.id) } }
    end
    @segment.update!(archived: true)
    Segments.stub(:estimate, ->(*) { flunk "must not evaluate an archived segment" }) { SegmentSizeSnapshotJob.new.perform(@segment.id) }
    assert_equal 0, SegmentSizeSnapshot.count
  end

  test "a busy segment is retried later, a bounded number of times" do
    Sidekiq::Testing.fake! do
      SegmentSizeSnapshotJob.clear
      Segments.stub(:estimate, ->(*) { raise Segments::Busy }) do
        SegmentSizeSnapshotJob.new.perform(@segment.id)
        SegmentSizeSnapshotJob.new.perform(@segment.id, SegmentSizeSnapshotJob::MAX_BUSY_RETRIES)
      end
      assert_equal [[@segment.id, 1]], SegmentSizeSnapshotJob.jobs.map { |j| j["args"] }
    end
  end

  test "the tick only enqueues, one job per active segment" do
    Segment.create!(project: projects(:one), name: "Old", definition: DEFINITION, archived: true)
    Sidekiq::Testing.fake! do
      SegmentSizeSnapshotJob.clear
      SegmentSnapshotTickJob.new.perform
      assert_equal [[@segment.id]], SegmentSizeSnapshotJob.jobs.map { |j| j["args"] }
    end
  end
end
