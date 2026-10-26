require "test_helper"

class SegmentFilterTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  test "no segment id means no clause" do
    assert_nil SegmentFilter.clause(project: projects(:one), segment_id: nil)
    assert_nil SegmentFilter.clause(project: projects(:one), segment_id: "")
  end

  test "without the enterprise tree a segment id is ignored" do
    skip "enterprise tree present" if defined?(Segments)
    assert_nil SegmentFilter.clause(project: projects(:one), segment_id: "abc")
  end

  test "enterprise errors surface as core errors" do
    skip "enterprise tree absent" unless defined?(Segments)
    { ActiveRecord::RecordNotFound => SegmentFilter::NotFound, Segments::Busy => SegmentFilter::Busy,
      Segments::InvalidDefinition => SegmentFilter::Invalid, Segments::WindowExpired => SegmentFilter::Invalid }.each do |raised, expected|
      Segments.stub(:visitor_filter_sql, ->(*, **) { raise raised }) do
        assert_raises(expected) { SegmentFilter.clause(project: projects(:one), segment_id: "abc") }
      end
    end
  end

  test "the column is allow-listed" do
    assert_raises(ArgumentError) { SegmentFilter.clause(project: projects(:one), segment_id: "abc", column: "1=1 OR visitor_id") }
  end

  test "effective is forwarded to visitor_filter_sql" do
    skip "enterprise tree absent" unless defined?(Segments)
    captured = nil
    stub = lambda do |*, **kw|
      captured = kw
      "visitor_id IN (1)"
    end
    Segments.stub(:visitor_filter_sql, stub) do
      SegmentFilter.clause(project: projects(:one), segment_id: "abc", effective: true)
    end
    assert_equal true, captured[:effective]
  end

  test "without the enterprise tree effective is still a no-op" do
    skip "enterprise tree present" if defined?(Segments)
    assert_nil SegmentFilter.clause(project: projects(:one), segment_id: "abc", effective: true)
  end
end
