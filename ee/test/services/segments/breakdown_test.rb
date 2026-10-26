require "test_helper"

class SegmentsBreakdownTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  fixtures :instances, :projects

  setup do
    skip_unless_clickhouse!
    @__clickhouse_test_started = true
    @ch_auto_rebuild_breakdowns = true
    @project = projects(:one)
    @pid = @project.id
    insert_ch_user_profiles([profile(1, "ana", "plan" => "pro"), profile(2, "ana", {}), profile(3, "", "plan" => "free"), profile(4, "", {})])
    insert_ch_events([ev(1, platform: "android", at: ts(10)), ev(2, platform: "ios", at: ts(2)), ev(3, platform: "ios", at: ts(3))])
    @manifest = Segments::Results::Manifest.new(result_id: "f" * 32, project_id: @pid, persons: 3, devices: 4, rows: 4, incomplete: false)
    rows = [[1, "i:ana"], [2, "i:ana"], [3, "v:3"], [4, "v:4"]].map do |id, pk|
      { project_id: @pid, result_id: @manifest.result_id, visitor_id: id, eff_visitor_id: id, person_key: pk }
    end
    Clickhouse.with { |c| c.insert("segment_results", rows) }
  end

  teardown { REDIS.with { |c| c.del(Segments::Permits::GLOBAL_KEY, Segments::Permits.project_key(@pid)) } }

  def ts(days_ago) = (Time.now.utc - days_ago.days).strftime("%Y-%m-%d %H:%M:%S.000")
  def profile(id, ident, props) = { project_id: @pid, visitor_id: id, sdk_identifier: ident, properties: props, first_seen: ts(30), last_seen: ts(30) }
  def ev(visitor, platform:, at:) = { project_id: @pid, visitor_id: visitor, event_type: "app_open", platform: platform, created_at: at }
  def buckets(by) = Segments::Breakdown.call(project: @project, manifest: @manifest, by: by)[:buckets].to_h { |b| [b[:value], b[:persons]] }

  test "platform uses each person's latest value across their visitors, and buckets sum to persons" do
    out = buckets("platform")
    assert_equal({ "ios" => 2, "unknown" => 1 }, out)
    assert_equal 3, out.values.sum
  end

  test "profile property breakdown reads current attributes" do
    assert_equal({ "pro" => 1, "free" => 1, "unknown" => 1 }, buckets("properties.plan"))
  end

  test "unknown dimension is rejected" do
    assert_raises(ArgumentError) { Segments::Breakdown.call(project: @project, manifest: @manifest, by: "ip") }
    assert_raises(ArgumentError) { Segments::Breakdown.call(project: @project, manifest: @manifest, by: "properties.bad`key") }
  end

  # argMax tie: a valueless visitor seen later must not beat a sibling that has a value.
  test "a person's real value wins even when the valueless visitor is seen more recently" do
    profiles = [
      { project_id: @pid, visitor_id: 5, sdk_identifier: "carol", properties: { "plan" => "pro" }, first_seen: ts(30), last_seen: ts(20) },
      { project_id: @pid, visitor_id: 6, sdk_identifier: "carol", properties: {}, first_seen: ts(5), last_seen: ts(1) }
    ]
    Clickhouse.with { |c| c.insert("user_profiles", profiles) }
    manifest = Segments::Results::Manifest.new(result_id: "a" * 32, project_id: @pid, persons: 1, devices: 2, rows: 2, incomplete: false)
    rows = [[5, "i:carol"], [6, "i:carol"]].map do |id, pk|
      { project_id: @pid, result_id: manifest.result_id, visitor_id: id, eff_visitor_id: id, person_key: pk }
    end
    Clickhouse.with { |c| c.insert("segment_results", rows) }
    out = Segments::Breakdown.call(project: @project, manifest: manifest, by: "properties.plan")[:buckets].to_h { |b| [b[:value], b[:persons]] }
    assert_equal({ "pro" => 1 }, out)
  end

  # "unknown" means "no value", never "cut off by LIMIT"; the tail folds into "other".
  test "buckets beyond the top 50 fold into other, and unknown only counts persons with no value" do
    profiles = (1..60).map do |i|
      { project_id: @pid, visitor_id: 100 + i, sdk_identifier: "", properties: { "tag" => "v#{i}" }, first_seen: ts(30), last_seen: ts(30) }
    end
    profiles << { project_id: @pid, visitor_id: 200, sdk_identifier: "", properties: {}, first_seen: ts(30), last_seen: ts(30) }
    insert_ch_user_profiles(profiles)
    manifest = Segments::Results::Manifest.new(result_id: "b" * 32, project_id: @pid, persons: 61, devices: 61, rows: 61, incomplete: false)
    rows = (1..60).map { |i| { project_id: @pid, result_id: manifest.result_id, visitor_id: 100 + i, eff_visitor_id: 100 + i, person_key: "v:#{100 + i}" } }
    rows << { project_id: @pid, result_id: manifest.result_id, visitor_id: 200, eff_visitor_id: 200, person_key: "v:200" }
    Clickhouse.with { |c| c.insert("segment_results", rows) }

    assert_includes Segments::Breakdown.sql(@project, manifest, "properties.tag"), "LIMIT 50"

    buckets = Segments::Breakdown.call(project: @project, manifest: manifest, by: "properties.tag")[:buckets]
    named = buckets.reject { |b| %w[other unknown].include?(b[:value]) }
    other = buckets.find { |b| b[:value] == "other" }
    unknown = buckets.find { |b| b[:value] == "unknown" }
    assert_equal 50, named.size
    assert_equal 10, other[:persons]
    assert_equal 1, unknown[:persons]
    assert_equal 61, buckets.sum { |b| b[:persons] }
  end
end
