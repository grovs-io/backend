require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class AnalyticsSegmentFilterTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include ClickhouseTestHelper

  fixtures :instances, :users, :instance_roles, :projects

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @pid = @project.id
    @headers = doorkeeper_headers_for(users(:admin_user))
    @matched = 5_001
    @other = 5_002

    # @matched gets a non-matching event too, proving the filter is visitor- not event-level.
    insert_ch_events([ev(@matched, "checkout"), ev(@matched, "browse"), ev(@other, "browse")])
    insert_ch_session_summaries([
      { project_id: @pid, session_id: "s_matched", visitor_id: @matched, event_date: Date.current.to_s,
        started_at: ts_str(1), ended_at: ts_str(1) },
      { project_id: @pid, session_id: "s_other", visitor_id: @other, event_date: Date.current.to_s,
        started_at: ts_str(1), ended_at: ts_str(1) }
    ])
  end

  teardown do
    REDIS.with { |c| c.keys("segments:result*").each { |k| c.del(k) } }
    REDIS.with { |c| c.del(Segments::Permits::GLOBAL_KEY, Segments::Permits.project_key(@pid)) }
  end

  def ts(days_ago) = (Time.now.utc - days_ago.days)
  def ts_str(days_ago) = ts(days_ago).strftime("%Y-%m-%d %H:%M:%S.000")
  def ev(visitor, name) = { project_id: @pid, visitor_id: visitor, event_type: "custom", event_name: name, created_at: ts_str(2) }

  def segment_for(project: @project, name: "checkout")
    Segment.create!(project: project, name: "Buyers", definition: {
      "version" => 1, "operator" => "or", "groups" => [{ "operator" => "and", "conditions" => [
        { "type" => "event", "event_name" => name, "window" => { "last_days" => 30 } }
      ] }]
    })
  end

  def live(&blk) = Clickhouse.stub(:read_enabled?, true) { Clickhouse.stub(:enabled?, true, &blk) }

  def date_params
    { start_date: 7.days.ago.to_date.to_s, end_date: Date.current.to_s }
  end

  def get_all_four(segment_id)
    [
      ["#{API_PREFIX}/projects/#{@pid}/analytics/events", date_params.merge(segment_id: segment_id)],
      ["#{API_PREFIX}/projects/#{@pid}/analytics/events/volume", date_params.merge(segment_id: segment_id)],
      ["#{API_PREFIX}/projects/#{@pid}/analytics/sessions", date_params.merge(segment_id: segment_id)],
      ["#{API_PREFIX}/projects/#{@pid}/analytics/retention/summary", { segment_id: segment_id }]
    ].each do |path, params|
      get path, params: params, headers: @headers
      yield
    end
  end

  test "events index filters to the segment's members, and total_count matches" do
    segment = segment_for
    live do
      get "#{API_PREFIX}/projects/#{@pid}/analytics/events",
          params: date_params.merge(segment_id: segment.hashid, include_count: "true"),
          headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 2, json["data"].size
    assert json["data"].all? { |r| r["visitor_id"] == @matched }
    assert_equal 2, json["total_count"]
  end

  test "events volume sums only the segment's members" do
    segment = segment_for
    live do
      get "#{API_PREFIX}/projects/#{@pid}/analytics/events/volume",
          params: date_params.merge(segment_id: segment.hashid),
          headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 2, json["buckets"].sum { |b| b["count"].to_i }
  end

  test "sessions filters to the segment's members" do
    segment = segment_for
    live do
      get "#{API_PREFIX}/projects/#{@pid}/analytics/sessions",
          params: date_params.merge(segment_id: segment.hashid),
          headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal ["s_matched"], json["data"].map { |r| r["session_id"] }
  end

  test "retention summary answers 200 with a segment_id" do
    segment = segment_for
    live do
      get "#{API_PREFIX}/projects/#{@pid}/analytics/retention/summary",
          params: { segment_id: segment.hashid },
          headers: @headers
    end
    assert_response :ok
  end

  test "an unknown segment_id is a 404 on all four endpoints" do
    live { get_all_four("not-a-real-segment") { assert_response :not_found } }
  end

  test "an archived segment_id is a 404 on all four endpoints" do
    segment = segment_for
    segment.update!(archived: true)
    live { get_all_four(segment.hashid) { assert_response :not_found } }
  end

  test "another project's segment_id is a 404 on all four endpoints" do
    segment = segment_for(project: projects(:two))
    live { get_all_four(segment.hashid) { assert_response :not_found } }
  end

  test "a busy segment result is a 429" do
    segment = segment_for
    Segments::Results.stub(:for, ->(**) { raise Segments::Busy }) do
      live do
        get "#{API_PREFIX}/projects/#{@pid}/analytics/events", params: date_params.merge(segment_id: segment.hashid), headers: @headers
      end
    end
    assert_response :too_many_requests
    assert_equal "segment_busy", JSON.parse(response.body)["error_code"]
  end
end
