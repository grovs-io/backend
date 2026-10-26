require "test_helper"

class EventExportJobTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include ActionMailer::TestHelper
  fixtures :instances, :users, :instance_roles, :projects, :devices, :visitors

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    insert_ch_events((1..3).map do |i|
      { project_id: @project.id, event_type: "install", created_at: EventStream::Outbox.format_ts(Time.utc(2026, 9, 10, 12, 0, i)), event_id: "x#{i}",
        device_id: devices(:ios_device).id, visitor_id: visitors(:ios_visitor).id }
    end)
    insert_ch_events([{ project_id: @project.id, event_type: "install", created_at: EventStream::Outbox.format_ts(Time.utc(2026, 9, 20, 12, 0, 0)),
                        event_id: "out", device_id: 1, visitor_id: 1 }])
  end

  test "writes a gzip ndjson file for the range and emails the requester" do
    assert_emails 1 do
      EventExportJob.new.perform(@project.id, "2026-09-10", "2026-09-11", users(:admin_user).id, nil)
    end
    file = DownloadableFile.order(:id).last
    assert_match(/events_.*\.ndjson\.gz\z/, file.file.filename.to_s)
    ids = Zlib::GzipReader.new(StringIO.new(file.file.download)).read.split("\n").map { |l| JSON.parse(l)["id"] }
    assert_equal %w[x1 x2 x3], ids
  end

  test "into a destination: pushes through the adapter in batches without touching the bookmark" do
    dest = EventDestination.new(project: @project, name: "w", kind: "webhook", settings: { "url" => "https://hooks.example.com/in" })
    dest.generate_signing_secret
    dest.save!
    dest.rewind!(to: 1.hour.ago)
    before = dest.reload.events_cursor_at
    posted = []
    capture = lambda do |_url, opts|
      posted << opts[:body]
      Struct.new(:code, :body).new(200, "")
    end
    HTTParty.stub(:post, capture) do
      EventExportJob.new.perform(@project.id, "2026-09-10", "2026-09-11", users(:admin_user).id, dest.id)
    end
    assert_equal %w[x1 x2 x3], posted.flat_map { |b| b.split("\n").map { |l| JSON.parse(l)["id"] } }
    assert_equal before, dest.reload.events_cursor_at
  end

  test "runs even while live delivery holds the destination lock" do
    dest = EventDestination.new(project: @project, name: "w", kind: "webhook", settings: { "url" => "https://hooks.example.com/in" })
    dest.generate_signing_secret
    dest.save!
    REDIS.with { |c| c.set("sidekiq:single_flight:event_destination:#{dest.id}", "live", nx: true, ex: 60) }
    posted = []
    capture = lambda do |_url, opts|
      posted << opts[:body]
      Struct.new(:code, :body).new(200, "")
    end
    HTTParty.stub(:post, capture) do
      EventExportJob.new.perform(@project.id, "2026-09-10", "2026-09-11", users(:admin_user).id, dest.id)
    end
    assert_equal %w[x1 x2 x3], posted.flat_map { |b| b.split("\n").map { |l| JSON.parse(l)["id"] } }
  end

  test "exports purchases in the range, latest version only" do
    Clickhouse.with do |c|
      c.insert("purchase_events", [
        { project_id: @project.id, event_type: "buy", transaction_id: "t1", usd_price_cents: 100, currency: "USD",
          purchase_date: EventStream::Outbox.format_ts(Time.utc(2026, 9, 10, 9)), created_at: EventStream::Outbox.format_ts(Time.utc(2026, 9, 10, 9)) },
        { project_id: @project.id, event_type: "buy", transaction_id: "t1", usd_price_cents: 120, currency: "USD",
          purchase_date: EventStream::Outbox.format_ts(Time.utc(2026, 9, 10, 9)), created_at: EventStream::Outbox.format_ts(Time.utc(2026, 9, 12, 9)) },
        { project_id: @project.id, event_type: "buy", transaction_id: "t2", usd_price_cents: 100, currency: "USD",
          purchase_date: EventStream::Outbox.format_ts(Time.utc(2026, 9, 25, 9)), created_at: EventStream::Outbox.format_ts(Time.utc(2026, 9, 25, 9)) }
      ])
    end
    EventExportJob.new.perform(@project.id, "2026-09-10", "2026-09-11", users(:admin_user).id, nil)
    lines = Zlib::GzipReader.new(StringIO.new(DownloadableFile.order(:id).last.file.download)).read.split("\n").map { |l| JSON.parse(l) }
    purchases = lines.select { |l| l["type"] == "purchase" }
    assert_equal [["t1", 120]], purchases.map { |p| [p.dig("purchase", "transaction_id"), p.dig("purchase", "usd_price_cents")] }
  end

  test "a correction dated outside the range hides its older version" do
    at = ->(time) { EventStream::Outbox.format_ts(time) }
    Clickhouse.with do |c|
      c.insert("purchase_events", [
        { project_id: @project.id, event_type: "buy", transaction_id: "t9", usd_price_cents: 100, currency: "USD",
          purchase_date: at.call(Time.utc(2026, 9, 10, 9)), created_at: at.call(Time.utc(2026, 9, 10, 9)) },
        { project_id: @project.id, event_type: "buy", transaction_id: "t9", usd_price_cents: 100, currency: "USD",
          purchase_date: at.call(Time.utc(2026, 9, 10, 9)), recorded_at: at.call(Time.utc(2026, 9, 25, 9)),
          created_at: at.call(Time.utc(2026, 9, 26, 9)) }
      ])
    end
    EventExportJob.new.perform(@project.id, "2026-09-10", "2026-09-11", users(:admin_user).id, nil)
    lines = Zlib::GzipReader.new(StringIO.new(DownloadableFile.order(:id).last.file.download)).read.split("\n").map { |l| JSON.parse(l) }
    assert_empty(lines.select { |l| l.dig("purchase", "transaction_id") == "t9" })
  end

  test "an export larger than one page keeps paging" do
    job = EventExportJob.new
    job.stub(:page_size, 2) do
      job.perform(@project.id, "2026-09-10", "2026-09-11", users(:admin_user).id, nil)
    end
    ids = Zlib::GzipReader.new(StringIO.new(DownloadableFile.order(:id).last.file.download)).read.split("\n").map { |l| JSON.parse(l)["id"] }
    assert_equal %w[x1 x2 x3], ids
  end

  test "a non-member requester or a foreign destination does nothing" do
    other = EventDestination.create!(project: projects(:two), name: "w", kind: "webhook", settings: { "url" => "https://h.example.com" })
    assert_no_difference("DownloadableFile.count") do
      HTTParty.stub(:post, ->(*) { flunk "must not deliver" }) do
        EventExportJob.new.perform(@project.id, "2026-09-10", "2026-09-11", users(:super_admin_user).id, nil)
        EventExportJob.new.perform(@project.id, "2026-09-10", "2026-09-11", users(:admin_user).id, other.id)
      end
    end
  end

  test "the kill switch defers a push to a destination instead of dropping it" do
    dest = EventDestination.new(project: @project, name: "w", kind: "webhook", settings: { "url" => "https://hooks.example.com/in" })
    dest.generate_signing_secret
    dest.save!
    ENV["EVENT_STREAM_ENABLED"] = "false"
    deferred = nil
    EventExportJob.stub(:perform_in, ->(*args) { deferred = args }) do
      HTTParty.stub(:post, ->(*) { flunk "must not deliver while the switch is off" }) do
        EventExportJob.new.perform(@project.id, "2026-09-10", "2026-09-11", users(:admin_user).id, dest.id)
      end
    end
    assert_equal [15.minutes, @project.id, "2026-09-10", "2026-09-11", users(:admin_user).id, dest.id], deferred.first(6)
    assert deferred.last.present?, "a deferral carries the export id so its checkpoint survives"
  ensure
    ENV.delete("EVENT_STREAM_ENABLED")
  end

  def webhook_destination
    dest = EventDestination.new(project: @project, name: "w", kind: "webhook", settings: { "url" => "https://hooks.example.com/in" })
    dest.generate_signing_secret
    dest.save!
    dest
  end

  def ids_of(posted) = posted.flat_map { |b| b.split("\n").map { |l| JSON.parse(l)["id"] } }

  test "pages one day at a time in sort-key order, never across the whole range" do
    insert_ch_events([
      { project_id: @project.id, event_type: "app_open", created_at: EventStream::Outbox.format_ts(Time.utc(2026, 9, 10, 1)), event_id: "a1",
        device_id: 1, visitor_id: 1 },
      { project_id: @project.id, event_type: "app_open", created_at: EventStream::Outbox.format_ts(Time.utc(2026, 9, 11, 1)), event_id: "b1",
        device_id: 1, visitor_id: 1 }
    ])
    job = EventExportJob.new
    days = []
    original = job.method(:query_rows)
    spy = lambda do |sql, **placeholders|
      days << placeholders[:day] if sql == EventExportJob::EVENTS_PAGE_SQL
      original.call(sql, **placeholders)
    end
    job.stub(:page_size, 2) do
      job.stub(:query_rows, spy) { job.perform(@project.id, "2026-09-10", "2026-09-11", users(:admin_user).id, nil) }
    end
    ids = Zlib::GzipReader.new(StringIO.new(DownloadableFile.order(:id).last.file.download)).read.split("\n").map { |l| JSON.parse(l)["id"] }
    assert_equal %w[a1 x1 x2 x3 b1], ids, "within a day rows follow (event_type, event_id)"
    assert_equal %w[2026-09-10 2026-09-10 2026-09-10 2026-09-11], days
  end

  test "a retried push resumes after the last delivered page instead of re-pushing from the start" do
    dest = webhook_destination
    posted = []
    calls = 0
    flaky = lambda do |_url, opts|
      calls += 1
      next Struct.new(:code, :body).new(500, "down") if calls == 2

      posted << opts[:body]
      Struct.new(:code, :body).new(200, "")
    end
    job = EventExportJob.new
    job.jid = "retry-jid"
    job.stub(:page_size, 2) do
      HTTParty.stub(:post, flaky) do
        assert_raises(RuntimeError) { job.perform(@project.id, "2026-09-10", "2026-09-11", users(:admin_user).id, dest.id) }
        job.perform(@project.id, "2026-09-10", "2026-09-11", users(:admin_user).id, dest.id)
      end
    end
    assert_equal %w[x1 x2 x3], ids_of(posted)
    assert_nil REDIS.with { |c| c.get(EventExportJob.checkpoint_key("retry-jid")) }, "a finished export drops its checkpoint"
  end

  test "a backing-off or paused destination defers the push with its export id" do
    dest = webhook_destination
    deferred = []
    EventExportJob.stub(:perform_in, ->(*args) { deferred << args }) do
      HTTParty.stub(:post, ->(*) { flunk "must not push into a resting destination" }) do
        dest.update!(backoff_until: 2.minutes.from_now)
        EventExportJob.new.perform(@project.id, "2026-09-10", "2026-09-11", users(:admin_user).id, dest.id, "exp-1")
        dest.update!(backoff_until: nil, status: "paused")
        EventExportJob.new.perform(@project.id, "2026-09-10", "2026-09-11", users(:admin_user).id, dest.id, "exp-1")
      end
    end
    assert_in_delta 2.minutes.to_i, deferred.first.first.to_i, 5
    assert_equal 15.minutes, deferred.last.first
    assert(deferred.all? { |args| args.drop(1) == [@project.id, "2026-09-10", "2026-09-11", users(:admin_user).id, dest.id, "exp-1"] })
  end
end
