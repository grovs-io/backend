require "test_helper"

class SegmentsVisitorFilterTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  fixtures :instances, :projects

  setup do
    skip_unless_clickhouse!
    @__clickhouse_test_started = true
    @project = projects(:one)
    @pid = @project.id
    insert_ch_user_profiles([profile(1, "ana"), profile(3, "")])
    Clickhouse.with { |c| c.insert("visitor_identity_map", [{ project_id: @pid, from_visitor_id: 10, to_visitor_id: 1, updated_at: ts(5) }]) }
    insert_ch_events([ev(1), ev(3), ev(10)])
  end

  teardown do
    REDIS.with { |c| c.keys("segments:result*").each { |k| c.del(k) } }
    REDIS.with { |c| c.del(Segments::Permits::GLOBAL_KEY, Segments::Permits.project_key(@pid)) }
  end

  def ts(days_ago) = (Time.now.utc - days_ago.days).strftime("%Y-%m-%d %H:%M:%S.000")
  def profile(id, ident) = { project_id: @pid, visitor_id: id, sdk_identifier: ident, first_seen: ts(20), last_seen: ts(20) }
  def ev(visitor) = { project_id: @pid, visitor_id: visitor, event_type: "custom", event_name: "checkout", created_at: ts(2) }

  def segment_for(project, name = "checkout")
    definition = { "version" => 1, "operator" => "or", "groups" => [{ "operator" => "and", "conditions" => [
      { "type" => "event", "event_name" => name, "window" => { "last_days" => 30 } }
    ] }] }
    Segment.create!(project: project, name: "Checkout buyers", definition: definition)
  end

  def live(&) = Clickhouse.stub(:read_enabled?, true) { Clickhouse.stub(:enabled?, true, &) }

  def count_matching(clause)
    Clickhouse.with { |c| c.select_value("SELECT count() FROM events WHERE project_id = #{@pid} AND #{clause}") }.to_i
  end

  test "the clause counts members' events including a merged-away visitor's pre-merge events" do
    segment = segment_for(@project)
    clause = live { Segments.visitor_filter_sql(@project, segment.hashid) }
    assert_equal 3, count_matching(clause)
  end

  test "an archived segment raises RecordNotFound" do
    segment = segment_for(@project)
    segment.update!(archived: true)
    assert_raises(ActiveRecord::RecordNotFound) { live { Segments.visitor_filter_sql(@project, segment.hashid) } }
  end

  test "another project's segment raises RecordNotFound" do
    segment = segment_for(projects(:two))
    assert_raises(ActiveRecord::RecordNotFound) { live { Segments.visitor_filter_sql(@project, segment.hashid) } }
  end

  test "two calls within 5 minutes reuse the same result" do
    segment = segment_for(@project)
    first = live { Segments.visitor_filter_sql(@project, segment.hashid) }
    again = live { Segments.visitor_filter_sql(@project, segment.hashid) }
    assert_equal first[/result_id = '(\h{32})'/, 1], again[/result_id = '(\h{32})'/, 1]
  end

  test "an unallowed column raises ArgumentError before touching the segment" do
    segment = segment_for(@project)
    assert_raises(ArgumentError) { live { Segments.visitor_filter_sql(@project, segment.hashid, column: "1=1 OR visitor_id") } }
  end

  test "effective: true selects eff_visitor_id — matches the survivor but not the merged-away raw id" do
    segment = segment_for(@project)
    clause = live { Segments.visitor_filter_sql(@project, segment.hashid, effective: true) }
    assert_includes clause, "eff_visitor_id"
    assert_equal 2, count_matching(clause), "raw ids 1 and 3 match (they are their own effective id); raw id 10 does not"
  end
end
