require "test_helper"

class SegmentsFacadeTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  test "estimate refuses a segment that belongs to a different project" do
    segment = Segment.new(project: projects(:two), name: "x", definition: {})
    assert_raises(ArgumentError) { Segments.estimate(projects(:one), segment) }
  end
end
