require "test_helper"

class SegmentsResultsTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  fixtures :instances, :projects

  setup do
    skip_unless_clickhouse!
    @__clickhouse_test_started = true
    @project = projects(:one)
    @pid = @project.id
    insert_ch_user_profiles([profile(1, "ana"), profile(2, "ana"), profile(3, ""), profile(11, "bob")])
    Clickhouse.with { |c| c.insert("visitor_identity_map", [{ project_id: @pid, from_visitor_id: 10, to_visitor_id: 11, updated_at: ts(5) }]) }
    insert_ch_events([ev(1), ev(3), ev(10), ev(11)])
  end

  teardown do
    REDIS.with { |c| c.keys("segments:result*").each { |k| c.del(k) } }
    REDIS.with { |c| c.del(Segments::Permits::GLOBAL_KEY, Segments::Permits.project_key(@pid)) }
  end

  def ts(days_ago) = (Time.now.utc - days_ago.days).strftime("%Y-%m-%d %H:%M:%S.000")
  def profile(id, ident) = { project_id: @pid, visitor_id: id, sdk_identifier: ident, first_seen: ts(20), last_seen: ts(20) }
  def ev(visitor) = { project_id: @pid, visitor_id: visitor, event_type: "custom", event_name: "checkout", created_at: ts(2) }

  def forget_result_and_hold_lock
    key = REDIS.with { |c| c.keys("segments:result_key:*").first }
    REDIS.with do |c|
      c.del(key)
      c.set("#{key}:lock", 1, ex: 30)
    end
    key
  end

  def definition(name = "checkout")
    Segments::Definition.parse({ "version" => 1, "operator" => "or", "groups" => [{ "operator" => "and", "conditions" => [
      { "type" => "event", "event_name" => name, "window" => { "last_days" => 30 } }
    ] }] }, cutoff_date: Date.current - 365)
  end

  def live(&) = Clickhouse.stub(:read_enabled?, true) { Clickhouse.stub(:enabled?, true, &) }

  test "materialises raw and effective ids and writes a manifest with exact counts" do
    m = live { Segments::Results.for(project: @project, definition: definition) }
    assert_match(/\A\h{32}\z/, m.result_id)
    assert_equal 3, m.persons
    assert_equal 4, m.devices
    assert_equal 5, m.rows
    rows = Clickhouse.with { |c| c.select_all("SELECT visitor_id, eff_visitor_id, person_key FROM segment_results WHERE #{Segments::Results.scope_sql(m)} ORDER BY visitor_id") }
    assert_equal [[1, 1, "i:ana"], [2, 2, "i:ana"], [3, 3, "v:3"], [10, 11, "i:bob"], [11, 11, "i:bob"]],
                 rows.map { |r| [r["visitor_id"].to_i, r["eff_visitor_id"].to_i, r["person_key"]] }
  end

  test "an effective visitor reached only through an uncompressed merge chain still gets its own row" do
    Clickhouse.with do |c|
      c.insert("visitor_identity_map", [{ project_id: @pid, from_visitor_id: 20, to_visitor_id: 21, updated_at: ts(5) },
                                        { project_id: @pid, from_visitor_id: 21, to_visitor_id: 22, updated_at: ts(5) }])
    end
    insert_ch_events([ev(20).merge(event_name: "chained")])
    m = live { Segments::Results.for(project: @project, definition: definition("chained")) }
    rows = Clickhouse.with { |c| c.select_all("SELECT visitor_id, eff_visitor_id FROM segment_results WHERE #{Segments::Results.scope_sql(m)} ORDER BY visitor_id") }
    assert_equal [[20, 21], [21, 21]], rows.map { |r| [r["visitor_id"].to_i, r["eff_visitor_id"].to_i] }
  end

  test "a fresh result is reused instead of re-evaluated" do
    first = live { Segments::Results.for(project: @project, definition: definition) }
    again = live { Segments::Results.for(project: @project, definition: definition) }
    assert_equal first.result_id, again.result_id
  end

  test "a concurrent caller waits for the running build and reuses its result" do
    first = Segments::Results.for(project: @project, definition: definition)
    reuse_key = forget_result_and_hold_lock
    publish = -> { REDIS.with { |c| c.set(reuse_key, first.result_id, ex: 30) } }
    Segments::Runner.stub(:materialize, ->(*) { flunk "must not build twice" }) do
      Segments::Results.stub(:pause, publish) do
        assert_equal first.result_id, Segments::Results.for(project: @project, definition: definition).result_id
      end
    end
  end

  test "a caller that outwaits the running build gets Busy" do
    Segments::Results.for(project: @project, definition: definition)
    reuse_key = forget_result_and_hold_lock
    Segments::Results.stub(:pause, nil) do
      assert_raises(Segments::Busy) { Segments::Results.for(project: @project, definition: definition) }
    end
  end

  test "a waiter takes over when the running build fails" do
    Segments::Results.for(project: @project, definition: definition)
    reuse_key = forget_result_and_hold_lock
    release = -> { REDIS.with { |c| c.del("#{reuse_key}:lock") } }
    Segments::Results.stub(:pause, release) do
      assert_equal 3, Segments::Results.for(project: @project, definition: definition).persons
    end
  end

  test "an empty segment has a manifest with zero rows" do
    m = live { Segments::Results.for(project: @project, definition: definition("never-happened")) }
    assert_equal [0, 0, 0], [m.persons, m.devices, m.rows]
    assert_equal m.result_id, Segments::Results.fetch!(@pid, m.result_id).result_id
  end

  test "fetch! rejects an expired manifest, a malformed id and another project's id" do
    m = live { Segments::Results.for(project: @project, definition: definition) }
    assert_raises(Segments::ResultExpired) { Segments::Results.fetch!(projects(:two).id, m.result_id) }
    assert_raises(Segments::ResultExpired) { Segments::Results.fetch!(@pid, "'; DROP TABLE x; --") }
    REDIS.with { |c| c.del(Segments::Results.manifest_key(m.result_id)) }
    assert_raises(Segments::ResultExpired) { Segments::Results.fetch!(@pid, m.result_id) }
  end

  test "a failed insert leaves no manifest and no reuse key" do
    Segments::Runner.stub(:materialize, ->(*, **) { raise Analytics::QueryTooHeavy, "boom" }) do
      assert_raises(Analytics::QueryTooHeavy) { live { Segments::Results.for(project: @project, definition: definition) } }
    end
    assert_empty REDIS.with { |c| c.keys("segments:result*") }
  end
end
