require "test_helper"

class EventStream::OutboxTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  fixtures :instances, :users, :instance_roles, :projects

  setup do
    skip_unless_clickhouse!
    @project_id = 4242
  end

  def ts(time) = EventStream::Outbox.format_ts(time)
  def parse(value) = EventStream::Outbox.parse_ts(value)

  def read(project_id = @project_id, **over)
    EventStream::Outbox.read_events(**{ project_id: project_id, after_at: nil, after_id: "", event_types: nil, limit: 10,
                                        cutoff: 1.minute.from_now }.merge(over))
  end

  def read_purchases(**over)
    EventStream::Outbox.read_purchases(**{ project_id: @project_id, after_at: nil, after_id: "", limit: 10, cutoff: 1.minute.from_now }.merge(over))
  end

  def insert_purchases(rows)
    Clickhouse.with do |c|
      c.insert("purchase_events", rows.map do |row|
        { project_id: @project_id, usd_price_cents: 499, currency: "USD", purchase_date: ts(3.minutes.ago), created_at: ts(2.minutes.ago) }.merge(row)
      end)
    end
  end

  test "events inserted for an enabled project land in events_outbox, others do not" do
    EventStream::Outbox.enable_project!(@project_id)
    insert_ch_events([
      { project_id: @project_id, event_type: "install", created_at: ts(2.minutes.ago), device_id: 1, visitor_id: 1 },
      { project_id: 9999, event_type: "install", created_at: ts(2.minutes.ago), device_id: 2, visitor_id: 2 }
    ])

    rows = read
    assert_equal 1, rows.size
    assert_equal "install", rows.first["event_type"]
    assert_empty read(9999)
  end

  test "cursor read returns rows strictly after (outbox_at, event_id) in order" do
    EventStream::Outbox.enable_project!(@project_id)
    insert_ch_events((1..5).map do |i|
      { project_id: @project_id, event_type: "app_open", created_at: ts(10.minutes.ago + i), event_id: "e#{i}", device_id: 1, visitor_id: 1 }
    end)

    first = read(limit: 2)
    assert_equal %w[e1 e2], first.map { |r| r["event_id"] }

    rest = read(after_at: parse(first.last["outbox_at"]), after_id: "e2")
    assert_equal %w[e3 e4 e5], rest.map { |r| r["event_id"] }
  end

  test "a replayed row with an old ingested_at still sorts after a cursor taken before the replay" do
    EventStream::Outbox.enable_project!(@project_id)
    insert_ch_events([{ project_id: @project_id, event_type: "install", created_at: ts(1.minute.ago), event_id: "live", device_id: 1, visitor_id: 1 }])
    bookmark = read.last

    old = ts(2.hours.ago)
    insert_ch_events([{ project_id: @project_id, event_type: "install", created_at: old, ingested_at: old, event_id: "replayed", device_id: 1, visitor_id: 1 }])

    after = read(after_at: parse(bookmark["outbox_at"]), after_id: bookmark["event_id"])
    assert_equal ["replayed"], after.map { |r| r["event_id"] }
  end

  test "cutoff hides rows that reached the outbox after it" do
    EventStream::Outbox.enable_project!(@project_id)
    insert_ch_events([{ project_id: @project_id, event_type: "view", created_at: ts(Time.current), device_id: 1, visitor_id: 1 }])
    assert_empty read(cutoff: 1.minute.ago)
  end

  test "event_types filter" do
    EventStream::Outbox.enable_project!(@project_id)
    insert_ch_events([
      { project_id: @project_id, event_type: "time_spent", created_at: ts(2.minutes.ago), device_id: 1, visitor_id: 1 },
      { project_id: @project_id, event_type: "install", created_at: ts(2.minutes.ago), device_id: 1, visitor_id: 1 }
    ])
    assert_equal %w[install], read(event_types: %w[install]).map { |r| r["event_type"] }
  end

  test "disable and purge remove the allow-list row and the outbox rows" do
    EventStream::Outbox.enable_project!(@project_id)
    insert_ch_events([{ project_id: @project_id, event_type: "install", created_at: ts(2.minutes.ago), device_id: 1, visitor_id: 1 }])
    assert_includes EventStream::Outbox.enabled_project_ids, @project_id

    EventStream::Outbox.disable_project!(@project_id)
    EventStream::Outbox.purge_project!(@project_id)
    assert_not_includes EventStream::Outbox.enabled_project_ids, @project_id
    assert_empty read
  end

  test "sync_project! captures while an active pull token exists and stops when it is revoked" do
    project = projects(:one)
    token = EventStreamToken.new(project: project, name: "pull")
    token.generate_token
    token.save!

    EventStream::Outbox.sync_project!(project)
    assert_includes EventStream::Outbox.enabled_project_ids, project.id

    token.revoke!
    EventStream::Outbox.sync_project!(project)
    assert_not_includes EventStream::Outbox.enabled_project_ids, project.id
  end

  test "purchases inserted for an enabled project land in purchase_events_outbox" do
    EventStream::Outbox.enable_project!(@project_id)
    insert_purchases([{ event_type: "buy", transaction_id: "t1" }])
    assert_equal ["t1:buy"], read_purchases.map { |r| r["purchase_key"].rpartition(":").first }
  end

  test "a page split between two event types of one transaction loses neither" do
    EventStream::Outbox.enable_project!(@project_id)
    insert_purchases([{ event_type: "buy", transaction_id: "t1" }, { event_type: "cancel", transaction_id: "t1" }])

    first = read_purchases(limit: 1)
    rest = read_purchases(after_at: parse(first.last["outbox_at"]), after_id: first.last["purchase_key"])
    assert_equal %w[t1:buy t1:cancel], (first + rest).map { |r| r["purchase_key"].rpartition(":").first }
  end

  test "two versions of one purchase arriving together page apart without loss" do
    EventStream::Outbox.enable_project!(@project_id)
    insert_purchases([{ event_type: "buy", transaction_id: "t1", created_at: ts(3.minutes.ago) },
                      { event_type: "buy", transaction_id: "t1", created_at: ts(2.minutes.ago) }])

    first = read_purchases(limit: 1)
    rest = read_purchases(after_at: parse(first.last["outbox_at"]), after_id: first.last["purchase_key"])
    assert_equal 2, (first + rest).map { |r| r["purchase_key"] }.uniq.size
  end

  test "a full page of events keeps later purchases out of the merge" do
    row = ->(at) { { "outbox_at" => at } }
    events = [row.call("2026-09-15 10:00:00.000"), row.call("2026-09-15 10:00:01.000")]
    purchases = [row.call("2026-09-15 10:00:00.500"), row.call("2026-09-15 10:00:09.000")]

    merged = EventStream::Outbox.merge_by_arrival(events, purchases, 2)
    assert_equal %i[event purchase], merged.map(&:first)
    assert_equal ["2026-09-15 10:00:00.000", "2026-09-15 10:00:00.500"], merged.map { |_kind, r| r["outbox_at"] }
  end
end
