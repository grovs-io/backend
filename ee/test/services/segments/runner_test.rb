require "test_helper"

class SegmentsRunnerTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  FakeConn = Struct.new(:rows, :error, :queries) do
    def select_all(sql)
      queries << sql
      raise error if error

      rows
    end
  end

  setup do
    @project = projects(:one)
    @definition = Segments::Definition.parse(
      { "version" => 1, "operator" => "or", "groups" => [{ "operator" => "and", "conditions" => [
        { "type" => "event", "event_name" => "checkout", "window" => { "last_days" => 7 } }
      ] }] }, cutoff_date: Date.current - 365
    )
    @cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    REDIS.with do |c|
      c.del(Segments::Permits::GLOBAL_KEY, Segments::Permits.project_key(projects(:one).id), Segments::Permits.project_key(projects(:two).id))
    end
  end

  # The test env uses :null_store, so the cache behaviour needs a real store swapped in.
  def with_conn(conn, &)
    Rails.stub(:cache, @cache) do
      Clickhouse.stub(:read_enabled?, true) { Clickhouse.stub(:enabled?, true) { Clickhouse.stub(:with, ->(&blk) { blk.call(conn) }, &) } }
    end
  end

  test "returns persons and devices and applies the resource settings" do
    conn = FakeConn.new([{ "persons" => "12", "devices" => "15" }], nil, [])
    out = with_conn(conn) { Segments::Runner.estimate(project: @project, definition: @definition) }
    assert_equal({ persons: 12, devices: 15, approximate: false, incomplete: false }, out)
    assert_match(/SETTINGS max_execution_time = \d+, max_memory_usage = \d+, max_threads = 4/, conn.queries.first)
    assert_includes conn.queries.first, "join_use_nulls = 0"
  end

  test "a second identical estimate is served from cache" do
    conn = FakeConn.new([{ "persons" => "1", "devices" => "1" }], nil, [])
    with_conn(conn) { 2.times { Segments::Runner.estimate(project: @project, definition: @definition) } }
    assert_equal 1, conn.queries.size
  end

  test "the cache is scoped by project and by identifier-list generation" do
    conn = FakeConn.new([{ "persons" => "1", "devices" => "1" }], nil, [])
    with_conn(conn) do
      Segments::Runner.estimate(project: @project, definition: @definition)
      Segments::Runner.estimate(project: projects(:two), definition: @definition)
      Segments::Runner.estimate(project: @project, definition: @definition, list_generation: "g2")
    end
    assert_equal 3, conn.queries.size
  end

  test "a ClickHouse timeout or memory error becomes QueryTooHeavy" do
    conn = FakeConn.new([], ClickHouse::Client::DatabaseError.new("Code: 241. MEMORY_LIMIT_EXCEEDED"), [])
    assert_raises(Analytics::QueryTooHeavy) { with_conn(conn) { Segments::Runner.estimate(project: @project, definition: @definition) } }
  end

  test "a saturation DatabaseError becomes Clickhouse::Unavailable" do
    conn = FakeConn.new([], ClickHouse::Client::DatabaseError.new("Code: 202. TOO_MANY_SIMULTANEOUS_QUERIES"), [])
    assert_raises(Clickhouse::Unavailable) { with_conn(conn) { Segments::Runner.estimate(project: @project, definition: @definition) } }
    assert_equal 0, REDIS.with { |c| c.zcard(Segments::Permits::GLOBAL_KEY) }
  end

  test "ClickHouse being down becomes Clickhouse::Unavailable" do
    conn = FakeConn.new([], Errno::ECONNREFUSED.new, [])
    assert_raises(Clickhouse::Unavailable) { with_conn(conn) { Segments::Runner.estimate(project: @project, definition: @definition) } }
    assert_equal 0, REDIS.with { |c| c.zcard(Segments::Permits::GLOBAL_KEY) }
  end

  test "an unrelated DatabaseError still propagates as itself" do
    conn = FakeConn.new([], ClickHouse::Client::DatabaseError.new("Code: 62. Syntax error"), [])
    assert_raises(ClickHouse::Client::DatabaseError) { with_conn(conn) { Segments::Runner.estimate(project: @project, definition: @definition) } }
    assert_equal 0, REDIS.with { |c| c.zcard(Segments::Permits::GLOBAL_KEY) }
  end

  test "raises Unavailable when ClickHouse reads are off" do
    Clickhouse.stub(:read_enabled?, false) do
      assert_raises(Clickhouse::Unavailable) { Segments::Runner.estimate(project: @project, definition: @definition) }
    end
  end

  test "the timeout staircase orders ESTIMATE_TIMEOUT < request timeout < permit ttl" do
    conn = FakeConn.new([{ "persons" => "1", "devices" => "1" }], nil, [])
    captured_timeout = nil
    captured_ttl = nil
    capture_ttl = lambda do |_project_id, ttl:, **, &blk|
      captured_ttl = ttl
      blk.call
    end
    capture_timeout = lambda do |seconds, &blk|
      captured_timeout = seconds
      blk.call
    end
    Rails.stub(:cache, @cache) do
      Clickhouse.stub(:read_enabled?, true) do
        Clickhouse.stub(:enabled?, true) do
          Segments::Permits.stub(:with, capture_ttl) do
            Clickhouse.stub(:with_request_timeout, capture_timeout) do
              Clickhouse.stub(:with, ->(&blk) { blk.call(conn) }) do
                Segments::Runner.estimate(project: @project, definition: @definition)
              end
            end
          end
        end
      end
    end
    assert_includes conn.queries.first, "max_execution_time = #{Segments::Runner::ESTIMATE_TIMEOUT}"
    assert_operator Segments::Runner::ESTIMATE_TIMEOUT, :<, captured_timeout
    assert_operator captured_timeout, :<, captured_ttl
  end

  test "estimate acquires a permit scoped to the project's id" do
    conn = FakeConn.new([{ "persons" => "1", "devices" => "1" }], nil, [])
    captured_project_id = nil
    capture_project_id = lambda do |project_id, **_kwargs, &blk|
      captured_project_id = project_id
      blk.call
    end
    with_conn(conn) do
      Segments::Permits.stub(:with, capture_project_id) do
        Segments::Runner.estimate(project: @project, definition: @definition)
      end
    end
    assert_equal @project.id, captured_project_id
  end

  test "a Busy permit propagates and leaves the cache empty" do
    conn = FakeConn.new([{ "persons" => "1", "devices" => "1" }], nil, [])
    with_conn(conn) do
      Segments::Permits.stub(:with, ->(*, **) { raise Segments::Busy, "no permit" }) do
        assert_raises(Segments::Busy) { Segments::Runner.estimate(project: @project, definition: @definition) }
      end
      assert_equal 0, conn.queries.size

      Segments::Runner.estimate(project: @project, definition: @definition)
      assert_equal 1, conn.queries.size
    end
  end

  test "a QueryTooHeavy failure still releases the permit" do
    conn = FakeConn.new([], ClickHouse::Client::DatabaseError.new("Code: 241. MEMORY_LIMIT_EXCEEDED"), [])
    with_conn(conn) do
      assert_raises(Analytics::QueryTooHeavy) { Segments::Runner.estimate(project: @project, definition: @definition) }
    end
    assert_equal 0, REDIS.with { |c| c.zcard(Segments::Permits::GLOBAL_KEY) }
  end

  # Raises only on the first (platforms) query; the fallback's plain-estimate query then succeeds.
  FallbackConn = Struct.new(:queries) do
    def select_all(sql)
      queries << sql
      raise ClickHouse::Client::DatabaseError, "Code: 241. MEMORY_LIMIT_EXCEEDED" if queries.size == 1

      [{ "persons" => "3", "devices" => "5" }]
    end
  end

  test "estimate_with_platforms falls back to the plain estimate with nulls when the split is too heavy" do
    conn = FallbackConn.new([])
    out = with_conn(conn) { Segments::Runner.estimate_with_platforms(project: @project, definition: @definition) }
    assert_equal({ persons: 3, devices: 5, ios_devices: nil, android_devices: nil, approximate: false, incomplete: false }, out)
    assert_equal 2, conn.queries.size, "one attempt for the platforms query, one for the plain fallback"
    assert_includes conn.queries.first, "ios_devices"
    assert_not_includes conn.queries.last, "ios_devices"
    assert_equal 0, REDIS.with { |c| c.zcard(Segments::Permits::GLOBAL_KEY) }, "no permit held after the fallback completes"
  end

  test "estimate_with_platforms clamps an approximate split that overshoots devices" do
    assert_equal [5, 0], Segments::Runner.send(:clamp_platform_split, 5, 9, 3)
    assert_equal [0, 5], Segments::Runner.send(:clamp_platform_split, 5, -2, 9)
    assert_equal [2, 3], Segments::Runner.send(:clamp_platform_split, 5, 2, 3)
  end
end

class SegmentsRunnerClickhouseIntegrationTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  fixtures :instances, :projects

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    REDIS.with { |c| c.del(Segments::Permits::GLOBAL_KEY, Segments::Permits.project_key(@project.id)) } if @project
  end

  # No stubbing of Clickhouse.with: an unknown SETTINGS name fails here against real ClickHouse.
  test "estimate runs end to end against real ClickHouse" do
    at = 2.days.ago.strftime("%Y-%m-%d %H:%M:%S.%3N")
    insert_ch_user_profiles(project_id: @project.id, visitor_id: 9_501, sdk_identifier: "", first_seen: at, last_seen: at)
    insert_ch_events([
      { project_id: @project.id, visitor_id: 9_501, event_type: "custom", event_name: "checkout", created_at: at },
      { project_id: @project.id, visitor_id: 9_501, event_type: "custom", event_name: "checkout", created_at: at }
    ])
    definition = Segments::Definition.parse(
      { "version" => 1, "operator" => "or", "groups" => [{ "operator" => "and", "conditions" => [
        { "type" => "event", "event_name" => "checkout", "count" => 2, "window" => { "last_days" => 30 } }
      ] }] }, cutoff_date: Date.current - 365
    )
    raise definition.errors.inspect unless definition.valid?

    out = Rails.stub(:cache, @cache) do
      Clickhouse.stub(:read_enabled?, true) { Clickhouse.stub(:enabled?, true) { Segments::Runner.estimate(project: @project, definition: definition) } }
    end

    assert_equal({ persons: 1, devices: 1, approximate: false, incomplete: false }, out)
  end

  test "a current is_not leaves out people whose current value is unknown" do
    at = 2.days.ago.strftime("%Y-%m-%d %H:%M:%S.%3N")
    { 9_601 => "RO", 9_602 => "US", 9_603 => "" }.each do |visitor_id, country|
      insert_ch_user_profiles(project_id: @project.id, visitor_id: visitor_id, sdk_identifier: "", first_seen: at, last_seen: at, country: country)
    end
    definition = Segments::Definition.parse(
      { "version" => 1, "operator" => "or", "groups" => [{ "operator" => "and", "conditions" => [
        { "type" => "device", "field" => "country", "op" => "is_not", "value" => ["US"] }
      ] }] }, cutoff_date: Date.current - 365
    )
    raise definition.errors.inspect unless definition.valid?

    out = Rails.stub(:cache, @cache) do
      Clickhouse.stub(:read_enabled?, true) { Clickhouse.stub(:enabled?, true) { Segments::Runner.estimate(project: @project, definition: definition) } }
    end

    assert_equal 1, out[:persons]
  end
end
