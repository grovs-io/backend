require "test_helper"
require "sidekiq/testing"

class SegmentsIdentifierListTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  fixtures :instances, :projects

  DEFINITION = { "version" => 1, "operator" => "or", "groups" => [{ "operator" => "and", "conditions" => [
    { "type" => "event", "any" => true, "window" => { "last_days" => 30 } }
  ] }] }.freeze

  setup do
    skip_unless_clickhouse!
    @__clickhouse_test_started = true
    @segment = Segment.create!(project: projects(:one), name: "List", definition: DEFINITION)
  end

  teardown { REDIS.with { |c| c.del(Segments::IdentifierList.lock_key(@segment.id)) } }

  def live(&) = Clickhouse.stub(:enabled?, true, &)

  def stored(generation)
    Clickhouse.with { |c| c.select_all(Segments::IdentifierList.entries_sql(project_id: @segment.project_id, segment_id: @segment.id, generation: generation)) }
              .map { |r| r["identifier"] }.sort
  end

  def all_rows
    sql = "SELECT identifier FROM segment_identifier_entries WHERE project_id = #{@segment.project_id} AND segment_id = #{@segment.id}"
    Clickhouse.with { |c| c.select_all(sql) }
  end

  def with_batch(size)
    original = Segments::IdentifierList::BATCH
    Segments::IdentifierList.send(:remove_const, :BATCH)
    Segments::IdentifierList.const_set(:BATCH, size)
    yield
  ensure
    Segments::IdentifierList.send(:remove_const, :BATCH)
    Segments::IdentifierList.const_set(:BATCH, original)
  end

  # Lets the first insert really happen (so a real orphan row lands in CH), fails the second.
  def failing_on_second_insert(&block)
    original_insert = Clickhouse::Connection.instance_method(:insert)
    conn = Clickhouse.connection
    calls = 0
    conn.stub(:insert, lambda { |table, rows, **kwargs|
      calls += 1
      raise ClickHouse::Client::DatabaseError, "Code: 62. DB::Exception: boom" if calls == 2
      original_insert.bind(conn).call(table, rows, **kwargs)
    }, &block)
  end

  test "stores the list exactly as sent under a new generation and publishes it" do
    out = live { Segments::IdentifierList.replace!(@segment, ["Ana@x.io", "ana@x.io", " bob ", "Ana@x.io"]) }
    assert_match(/\A\h{32}\z/, out[:generation])
    assert_equal 3, out[:count]
    assert_equal out[:generation], @segment.reload.identifier_list_generation
    assert_equal [" bob ", "Ana@x.io", "ana@x.io"], stored(out[:generation])
  end

  test "preview returns the current list sorted, searchable and capped" do
    live { Segments::IdentifierList.replace!(@segment, ["zed", "Ana@x.io", "bob"]) }
    @segment.reload
    assert_equal({ identifiers: ["Ana@x.io", "bob", "zed"], more: false }, Segments::IdentifierList.preview(@segment))
    assert_equal ["Ana@x.io"], Segments::IdentifierList.preview(@segment, q: "ana")[:identifiers]
    assert_equal ["Ana@x.io", "bob"], Segments::IdentifierList.preview(@segment, q: "o")[:identifiers]

    live { Segments::IdentifierList.replace!(@segment, (1..101).map { |i| format("u%03d", i) }) }
    page = Segments::IdentifierList.preview(@segment.reload)
    assert_equal 100, page[:identifiers].size
    assert page[:more]
    assert_equal({ identifiers: [], more: false }, Segments::IdentifierList.preview(Segment.new))
  end

  test "to_csv quotes formula-looking identifiers and parse_csv reads them back unchanged" do
    ids = ["=cmd()", "'=cmd()", "''+1", "+1", "-2", "@x", "plain", "'kept"]
    live { Segments::IdentifierList.replace!(@segment, ids) }
    csv = Segments::IdentifierList.to_csv(@segment.reload)
    assert csv.start_with?("identifier\n")
    assert_includes csv, "'=cmd()"
    assert_equal ids.sort, Segments::IdentifierList.parse_csv(StringIO.new(csv)).sort
  end

  test "preview and download surface a ClickHouse outage as Unavailable, not a 500" do
    live { Segments::IdentifierList.replace!(@segment, ["a"]) }
    down = ->(*) { raise Errno::ECONNREFUSED, "clickhouse" }
    Clickhouse.stub(:with, down) do
      assert_raises(Clickhouse::Unavailable) { Segments::IdentifierList.preview(@segment.reload) }
      assert_raises(Clickhouse::Unavailable) { Segments::IdentifierList.to_csv(@segment) }
    end
    Segments::Runner.stub(:read, ->(*, **) { raise Analytics::QueryTooHeavy, "timeout" }) do
      assert_raises(Clickhouse::Unavailable) { Segments::IdentifierList.preview(@segment) }
    end
  end

  test "a failed insert publishes nothing and keeps the previous list" do
    first = live { Segments::IdentifierList.replace!(@segment, ["keep@x.io"]) }
    Clickhouse.stub(:with, ->(&) { raise ClickHouse::Client::DatabaseError, "Code: 62. DB::Exception: boom" }) do
      assert_raises(ClickHouse::Client::DatabaseError) { live { Segments::IdentifierList.replace!(@segment, ["new@x.io"]) } }
    end
    assert_equal first[:generation], @segment.reload.identifier_list_generation
    assert_equal ["keep@x.io"], stored(first[:generation])
  end

  test "a second upload while one holds the lock is refused" do
    REDIS.with { |c| c.set(Segments::IdentifierList.lock_key(@segment.id), "other", nx: true, ex: 60) }
    assert_raises(Segments::UploadInProgress) { live { Segments::IdentifierList.replace!(@segment, ["a"]) } }
  end

  test "rejects empty, oversized and malformed lists" do
    [[], ["x" * 257], [""], [{ "a" => 1 }], Array.new(200_001, "a")].each do |bad|
      assert_raises(Segments::InvalidList) { live { Segments::IdentifierList.replace!(@segment, bad) } }
    end
  end

  test "refuses when ClickHouse writes are off" do
    Clickhouse.stub(:enabled?, false) do
      assert_raises(Clickhouse::Unavailable) { Segments::IdentifierList.replace!(@segment, ["a"]) }
    end
  end

  test "parse_csv reads the first column and skips the header" do
    io = StringIO.new("identifier,name\nana@x.io,Ana\n\nbob@x.io,Bob\n")
    assert_equal %w[ana@x.io bob@x.io], Segments::IdentifierList.parse_csv(io)
  end

  test "parse_csv keeps an identifier named like the header once past the first row" do
    io = StringIO.new("\uFEFFidentifier\nidentifier\nIDENTIFIER\nana@x.io\n")
    assert_equal %w[identifier IDENTIFIER ana@x.io], Segments::IdentifierList.parse_csv(io)
    assert_equal %w[ana@x.io], Segments::IdentifierList.parse_csv(StringIO.new("ana@x.io\n"))
  end

  test "the purge job removes superseded generations only" do
    old = live { Segments::IdentifierList.replace!(@segment, ["old@x.io"]) }
    current = live { Segments::IdentifierList.replace!(@segment, ["new@x.io"]) }
    live { PurgeSegmentIdentifierGenerationsJob.new.perform(@segment.id) }
    assert_empty stored(old[:generation])
    assert_equal ["new@x.io"], stored(current[:generation])
  end

  test "the purge re-enqueues itself while an upload holds the lock, then deletes once released" do
    old = live { Segments::IdentifierList.replace!(@segment, ["old@x.io"]) }
    current = live { Segments::IdentifierList.replace!(@segment, ["new@x.io"]) }
    REDIS.with { |c| c.set(Segments::IdentifierList.lock_key(@segment.id), "other", nx: true, ex: 60) }
    Sidekiq::Testing.fake! do
      PurgeSegmentIdentifierGenerationsJob.clear
      live { PurgeSegmentIdentifierGenerationsJob.new.perform(@segment.id) }
      assert_equal 1, PurgeSegmentIdentifierGenerationsJob.jobs.size
    end
    assert_equal ["old@x.io"], stored(old[:generation])

    REDIS.with { |c| c.del(Segments::IdentifierList.lock_key(@segment.id)) }
    live { PurgeSegmentIdentifierGenerationsJob.new.perform(@segment.id) }
    assert_empty stored(old[:generation])
    assert_equal ["new@x.io"], stored(current[:generation])
  end

  test "a lock lost mid-upload is not published, and a purge is scheduled" do
    first = live { Segments::IdentifierList.replace!(@segment, ["keep@x.io"]) }
    Sidekiq::Testing.fake! do
      PurgeSegmentIdentifierGenerationsJob.clear
      Clickhouse.stub(:with, ->(&) { REDIS.with { |c| c.del(Segments::IdentifierList.lock_key(@segment.id)) } }) do
        assert_raises(Segments::UploadInProgress) { live { Segments::IdentifierList.replace!(@segment, ["new@x.io"]) } }
      end
      assert_equal 1, PurgeSegmentIdentifierGenerationsJob.jobs.size
    end
    assert_equal first[:generation], @segment.reload.identifier_list_generation
    assert_equal ["keep@x.io"], stored(first[:generation])
  end

  test "a failed batch mid-upload leaves the previous list published; the purge clears the orphan" do
    first = live { Segments::IdentifierList.replace!(@segment, ["keep@x.io"]) }
    Sidekiq::Testing.fake! do
      PurgeSegmentIdentifierGenerationsJob.clear
      with_batch(1) do
        failing_on_second_insert do
          assert_raises(ClickHouse::Client::DatabaseError) { live { Segments::IdentifierList.replace!(@segment, ["orphan1@x.io", "orphan2@x.io"]) } }
        end
      end
      assert_equal 1, PurgeSegmentIdentifierGenerationsJob.jobs.size
    end
    assert_equal first[:generation], @segment.reload.identifier_list_generation
    assert_equal 2, all_rows.size

    live { PurgeSegmentIdentifierGenerationsJob.new.perform(@segment.id) }
    rows = all_rows
    assert_equal 1, rows.size
    assert_equal "keep@x.io", rows.first["identifier"]
  end

  test "a first-ever failed upload is cleared entirely since no generation was ever published" do
    Sidekiq::Testing.fake! do
      PurgeSegmentIdentifierGenerationsJob.clear
      with_batch(1) do
        failing_on_second_insert do
          assert_raises(ClickHouse::Client::DatabaseError) { live { Segments::IdentifierList.replace!(@segment, ["a@x.io", "b@x.io"]) } }
        end
      end
      assert_equal 1, PurgeSegmentIdentifierGenerationsJob.jobs.size
    end
    assert_nil @segment.reload.identifier_list_generation
    assert_equal 1, all_rows.size

    live { PurgeSegmentIdentifierGenerationsJob.new.perform(@segment.id) }
    assert_empty all_rows
  end

  test "a ClickHouse outage during the insert surfaces as Unavailable, not a 500" do
    Clickhouse.stub(:with, ->(&) { raise Errno::ECONNREFUSED, "connect(2)" }) do
      assert_raises(Clickhouse::Unavailable) { live { Segments::IdentifierList.replace!(@segment, ["new@x.io"]) } }
    end
    Clickhouse.stub(:with, ->(&) { raise ClickHouse::Client::DatabaseError, "<html>502 Bad Gateway</html>" }) do
      assert_raises(Clickhouse::Unavailable) { live { Segments::IdentifierList.replace!(@segment, ["new@x.io"]) } }
    end
  end
end
