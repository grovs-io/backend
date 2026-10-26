require "test_helper"
require "sidekiq/testing"

class BatchEventPipelineConcurrencyTest < ActiveSupport::TestCase
  include ConcurrencyHelper
  include ClickhouseTestHelper

  self.use_transactional_tests = false # workers commit on their own connections; teardown cleans by hand

  fixtures :instances, :projects, :domains, :redirect_configs

  JID_PREFIX = "conc-pipeline".freeze
  POP_SIZE = 25
  DATES = [Date.new(2026, 9, 1), Date.new(2026, 9, 2), Date.new(2026, 9, 3)].freeze
  LINKED_TYPES = [Grovs::Events::OPEN, Grovs::Events::INSTALL, Grovs::Events::REINSTALL,
                  Grovs::Events::REACTIVATION, Grovs::Events::TIME_SPENT].freeze
  ALL_TYPES = (LINKED_TYPES + [Grovs::Events::APP_OPEN]).freeze

  setup do
    skip_unless_clickhouse!
    ensure_pool!
    @seed = Integer(ENV.fetch("CONCURRENCY_SEED", Random.new_seed % 1_000_000))
    @rng = Random.new(@seed)
    @projects = [projects(:one), projects(:two)]
    @devices = Array.new(12) do |i|
      Device.create!(user_agent: "ConcPipeline/#{i}", ip: "10.31.0.#{i}", remote_ip: "10.32.0.#{i}",
                     platform: i.even? ? Grovs::Platforms::IOS : Grovs::Platforms::ANDROID, vendor: "conc-pipe-#{SecureRandom.hex(6)}")
    end
    @visitors = {}
    @projects.each { |p| @devices.each { |d| @visitors[[p.id, d.id]] = Visitor.create!(project: p, device: d) } }
    @links = @projects.to_h do |project|
      domain = Domain.find_by!(project_id: project.id)
      referrer = @visitors[[project.id, @devices.first.id]]
      links = Array.new(5) do |i|
        Link.create!(domain: domain, redirect_config: redirect_configs(:one), path: "conc-pipe-#{SecureRandom.hex(5)}",
                     generated_from_platform: "ios", visitor_id: i.zero? ? referrer.id : nil)
      end
      [project.id, links]
    end
    redis_del_matching(BatchEventProcessorJob::REDIS_KEY)
  end

  teardown do
    next unless concurrency_enabled?

    device_ids = @devices&.map(&:id) || []
    link_ids = @links&.values&.flatten&.map(&:id) || []
    visitor_ids = @visitors&.values&.map(&:id) || []
    Event.where(device_id: device_ids).delete_all
    ClickhouseEventSpill.delete_all
    LinkDailyStatistic.where(link_id: link_ids).delete_all
    VisitorDailyStatistic.where(visitor_id: visitor_ids).delete_all
    VisitorLastVisit.where(visitor_id: visitor_ids).delete_all
    DeviceLastSeen.where(device_id: device_ids).delete_all
    Link.where(id: link_ids).delete_all
    Visitor.where(id: visitor_ids).update_all(inviter_id: nil)
    Visitor.where(id: visitor_ids).delete_all
    Device.where(id: device_ids).delete_all
    redis_del_matching(BatchEventProcessorJob::REDIS_KEY, "#{BatchEventProcessorJob::PROCESSING_KEY_PREFIX}:*",
                       "#{BatchEventProcessorJob::HEARTBEAT_PREFIX}:*", "#{BatchEventProcessorJob::DEDUP_PREFIX}:*")
  end

  # Catches: unsorted stat upserts deadlocking (a rolled-back batch is a :failure) and lost/double-counted events.
  test "N workers draining one mixed queue process every event exactly once with exact daily totals" do
    events = generate_events(scaled(3000))
    enqueue(events)

    statuses = drain_concurrently

    assert_all_batches_succeeded(statuses)
    assert_queue_drained
    assert_events_exactly_once(events)
    assert_exact_stats(events)
  end

  # Catches: orphan recovery that repushes a dead worker's list twice (double count) or never (loss).
  test "a worker killed mid-batch is recovered once by the racing survivors: no loss, no double count" do
    events = generate_events(scaled(2000))
    orphans = events.first(scaled(300))
    REDIS.with do |conn|
      orphans.each_slice(100).with_index do |slice, i|
        conn.lpush("#{BatchEventProcessorJob::PROCESSING_KEY_PREFIX}:#{JID_PREFIX}-dead-#{i}", slice.map { |e| e[:json] })
      end
    end
    enqueue(events.drop(orphans.size))

    statuses = drain_concurrently

    assert_all_batches_succeeded(statuses)
    assert_queue_drained
    assert_events_exactly_once(events)
    assert_exact_stats(events)
  end

  # Catches: CH-primary double inserts or drops under contention; PG still owns the daily stats.
  test "in ClickHouse-primary mode every event lands in ClickHouse exactly once and PG stats stay exact" do
    events = generate_events(scaled(2000))
    enqueue(events)

    statuses = with_clickhouse_primary { drain_concurrently }

    assert_all_batches_succeeded(statuses)
    assert_queue_drained
    assert_equal 0, Event.where(device_id: @devices.map(&:id)).count, "primary mode must not write PG events"
    assert_equal 0, ClickhouseEventSpill.count, "CH was up: nothing may spill"
    expected_ids = events.map { |e| e[:event_id] }
    scope = "project_id IN (#{@projects.map(&:id).join(',')}) AND event_type != 'user_referred'"
    ch_ids = Clickhouse.with do |c|
      c.select_all("SELECT event_id FROM events WHERE #{scope}").map { |r| r["event_id"] }
    end
    assert_equal expected_ids.size, ch_ids.size, "raw (un-merged) CH rows: each event inserted exactly once"
    assert_equal expected_ids.sort, ch_ids.sort
    assert_exact_stats(events)
  end

  private

  def generate_events(count)
    Array.new(count) do |i|
      project = @projects[@rng.rand(@projects.size)]
      device = @devices[@rng.rand(@devices.size)]
      type = ALL_TYPES[@rng.rand(ALL_TYPES.size)]
      link = LINKED_TYPES.include?(type) && @rng.rand < 0.8 ? @links[project.id].sample(random: @rng) : nil
      engagement = type == Grovs::Events::TIME_SPENT ? @rng.rand(1..90) : nil
      at = DATES[@rng.rand(DATES.size)].in_time_zone("UTC") + 12.hours + i.seconds
      session_id = "conc-#{i}"
      meta = EventIngestionService.frozen_ch_fields(type, project.id, device.id, link, at, "", session_id, engagement, nil)
      payload = { type: type, project_id: project.id, device_id: device.id, data: nil, link_id: link&.id,
                  engagement_time: engagement, created_at: at.iso8601(3), event_name: "", session_id: session_id, tags: [] }
      { type: type, project_id: project.id, device: device, link: link, value: engagement || 1, date: at.to_date,
        session_id: session_id, event_id: meta[:event_id], json: payload.merge(meta).to_json }
    end
  end

  def enqueue(events)
    REDIS.with { |conn| events.each_slice(1000) { |slice| conn.lpush(BatchEventProcessorJob::REDIS_KEY, slice.map { |e| e[:json] }) } }
  end

  # Mirrors perform's order (heartbeat, orphan recovery, pop/process) without its 55s wall-clock loop.
  def drain_concurrently
    run_concurrently do |i|
      job = BatchEventProcessorJob.new
      job.jid = "#{JID_PREFIX}-#{i}-#{SecureRandom.hex(3)}"
      job.send(:refresh_heartbeat)
      job.send(:recover_orphaned_events)
      statuses = []
      loop do
        raw = job.send(:pop_events, POP_SIZE)
        break if raw.empty?

        statuses << job.send(:process_batch, raw)
        break unless statuses.last == :success # a rolled-back batch already fails the test; don't spin on retries
      end
      REDIS.with { |c| c.del("#{BatchEventProcessorJob::HEARTBEAT_PREFIX}:#{job.jid}") }
      statuses
    end.flatten
  end

  def assert_all_batches_succeeded(statuses)
    failures = statuses.count { |s| s != :success }
    assert_equal 0, failures, "#{failures}/#{statuses.size} batches rolled back (deadlock or lock timeout); seed=#{@seed}"
  end

  def assert_queue_drained
    REDIS.with do |conn|
      assert_equal 0, conn.llen(BatchEventProcessorJob::REDIS_KEY), "events left pending"
      leftover = conn.keys("#{BatchEventProcessorJob::PROCESSING_KEY_PREFIX}:*").sum { |k| conn.llen(k) }
      assert_equal 0, leftover, "events left in processing lists"
    end
  end

  def assert_events_exactly_once(events)
    counts = Event.where(device_id: @devices.map(&:id)).where.not(event: Grovs::Events::USER_REFERRED)
                  .group(:session_id).count
    assert_equal events.size, counts.size, "lost events; seed=#{@seed}"
    dupes = counts.select { |_, n| n > 1 }
    assert_empty dupes, "events persisted more than once; seed=#{@seed}"
    referred = Event.where(device_id: @devices.map(&:id), event: Grovs::Events::USER_REFERRED).count
    assert_equal referrals(events).size, referred, "USER_REFERRED rows"
  end

  def referrals(events)
    events.select { |e| [Grovs::Events::INSTALL, Grovs::Events::REINSTALL].include?(e[:type]) && e[:link]&.visitor_id }
  end

  def assert_exact_stats(events)
    link_expected = Hash.new { |h, k| h[k] = Hash.new(0) }
    visitor_expected = Hash.new { |h, k| h[k] = Hash.new(0) }
    events.each do |e|
      metric = Grovs::Events::MAPPING[e[:type]]
      platform = e[:device].platform_for_metrics
      link_expected[[e[:link].id, e[:date], platform]][metric] += e[:value] if e[:link]
      visitor_expected[[@visitors[[e[:project_id], e[:device].id]].id, e[:date], platform]][metric] += e[:value]
    end
    referrals(events).each do |e|
      referrer = Visitor.find(e[:link].visitor_id)
      visitor_expected[[referrer.id, e[:date], referrer.device.platform_for_metrics]][:user_referred] += 1
    end

    metrics = Grovs::Events::MAPPING.values
    link_actual = LinkDailyStatistic.where(link_id: @links.values.flatten.map(&:id)).to_h do |row|
      [[row.link_id, row.event_date, row.platform], metrics.index_with { |m| row[m].to_i }.select { |_, v| v.positive? }]
    end
    visitor_actual = VisitorDailyStatistic.where(visitor_id: @visitors.values.map(&:id)).to_h do |row|
      [[row.visitor_id, row.event_date, row.platform], metrics.index_with { |m| row[m].to_i }.select { |_, v| v.positive? }]
    end
    assert_equal link_expected.transform_values(&:to_h), link_actual, "link daily stats drifted; seed=#{@seed}"
    assert_equal visitor_expected.transform_values(&:to_h), visitor_actual, "visitor daily stats drifted; seed=#{@seed}"
  end
end
