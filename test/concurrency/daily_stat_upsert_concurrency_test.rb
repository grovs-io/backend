require "test_helper"
require "sidekiq/testing"

class DailyStatUpsertConcurrencyTest < ActiveSupport::TestCase
  include ConcurrencyHelper

  self.use_transactional_tests = false # racing transactions must commit on separate connections

  fixtures :instances, :projects, :domains, :redirect_configs

  DATES = [Date.new(2026, 8, 10), Date.new(2026, 8, 11)].freeze
  PLATFORMS = [Grovs::Platforms::IOS, Grovs::Platforms::ANDROID, Grovs::Platforms::WEB].freeze
  METRICS = Grovs::Events::MAPPING.values.freeze

  setup do
    ensure_pool!
    @seed = Integer(ENV.fetch("CONCURRENCY_SEED", Random.new_seed % 1_000_000))
    @project = projects(:one)
    @device = Device.create!(user_agent: "ConcStats/1", ip: "10.41.0.1", remote_ip: "10.42.0.1", platform: "ios",
                             vendor: "conc-stats-#{SecureRandom.hex(6)}")
    @visitors = Array.new(4) do
      Visitor.create!(project: @project, device: Device.create!(user_agent: "ConcStats/v", ip: "10.41.1.1",
                                                                remote_ip: "10.42.1.1", platform: "ios",
                                                                vendor: "conc-stats-#{SecureRandom.hex(6)}"))
    end
    @links = Array.new(4) do
      Link.create!(domain: domains(:one), redirect_config: redirect_configs(:one), path: "conc-stats-#{SecureRandom.hex(5)}",
                   generated_from_platform: "ios")
    end
  end

  teardown do
    next unless concurrency_enabled?

    LinkDailyStatistic.where(link_id: @links&.map(&:id)).delete_all
    VisitorDailyStatistic.where(visitor_id: @visitors&.map(&:id)).delete_all
    DailyProjectMetric.where(project_id: @project&.id, event_date: DATES).delete_all
    DeviceLastSeen.where(device_id: devices_ids).delete_all
    Link.where(id: @links&.map(&:id)).delete_all
    Visitor.where(id: @visitors&.map(&:id)).delete_all
    Device.where(id: devices_ids).delete_all
  end

  # Catches: dropping the conflict-key sort in bulk_upsert_* (row locks taken in batch order deadlock).
  test "overlapping bulk link+visitor upserts in one transaction per worker: exact sums, no deadlocks" do
    rounds = scaled(25)
    link_keys = @links.product(DATES, PLATFORMS)
    visitor_keys = @visitors.product(DATES, PLATFORMS)

    per_thread = run_concurrently do |t|
      rng = Random.new(@seed + t)
      link_sum = Hash.new { |h, k| h[k] = Hash.new(0) }
      visitor_sum = Hash.new { |h, k| h[k] = Hash.new(0) }
      deadlocks = 0
      rounds.times do
        break if deadlocks.positive?

        link_stats = link_keys.shuffle(random: rng).map do |link, date, platform|
          { project_id: @project.id, link_id: link.id, event_date: date, platform: platform, metrics: random_metrics(rng) }
        end
        visitor_stats = visitor_keys.shuffle(random: rng).map do |visitor, date, platform|
          { project_id: @project.id, visitor_id: visitor.id, invited_by_id: nil, event_date: date, platform: platform,
            metrics: random_metrics(rng) }
        end
        ActiveRecord::Base.transaction do
          VisitorDailyStatService.bulk_upsert_visitor_stats(visitor_stats)
          LinkDailyStatService.bulk_upsert_link_stats(link_stats)
        end
        link_stats.each { |s| s[:metrics].each { |m, v| link_sum[[s[:link_id], s[:event_date], s[:platform]]][m] += v } }
        visitor_stats.each { |s| s[:metrics].each { |m, v| visitor_sum[[s[:visitor_id], s[:event_date], s[:platform]]][m] += v } }
      rescue ActiveRecord::StatementInvalid => e
        raise unless deadlock?(e)

        deadlocks += 1
      end
      { link: link_sum, visitor: visitor_sum, deadlocks: deadlocks }
    end

    assert_equal 0, per_thread.sum { |r| r[:deadlocks] }, "deadlocks between bulk upserts; seed=#{@seed}"
    assert_equal merge_sums(per_thread.map { |r| r[:link] }), link_rows, "link sums; seed=#{@seed}"
    assert_equal merge_sums(per_thread.map { |r| r[:visitor] }), visitor_rows, "visitor sums; seed=#{@seed}"
  end

  # Catches: a check-then-insert first write (two inserters of a new key) losing an increment or raising.
  test "many single-row increments racing on fresh keys: every increment lands exactly once" do
    increments = scaled(60)
    link = @links.first
    visitor = @visitors.first

    run_concurrently do |t|
      increments.times do |n|
        date = DATES[n % DATES.size]
        VisitorDailyStatService.increment_visitor_event(visitor: visitor, event_type: :revenue, platform: "ios",
                                                        event_date: date, project_id: @project.id, value: t + 1)
        DailyProjectMetric.increment!(@project.id, "ios", date, revenue: t + 1, units_sold: 1)
        LinkDailyStatService.increment_link_event(event_type: :revenue, project_id: @project.id, link_id: link.id,
                                                  platform: "ios", event_date: date, value: t + 1)
      end
    end

    per_date = (1..THREADS).sum * (increments / DATES.size)
    DATES.each do |date|
      assert_equal per_date, VisitorDailyStatistic.find_by!(visitor_id: visitor.id, event_date: date, platform: "ios").revenue
      assert_equal per_date, LinkDailyStatistic.find_by!(link_id: link.id, event_date: date, platform: "ios").revenue
      dpm = DailyProjectMetric.find_by!(project_id: @project.id, event_date: date, platform: "ios")
      assert_equal per_date, dpm.revenue
      assert_equal THREADS * (increments / DATES.size), dpm.units_sold
    end
  end

  private

  def devices_ids
    [@device&.id, *@visitors&.map(&:device_id)].compact
  end

  def random_metrics(rng)
    METRICS.sample(2, random: rng).index_with { rng.rand(1..9) }
  end

  def merge_sums(hashes)
    acc = Hash.new { |h, k| h[k] = Hash.new(0) }
    hashes.each { |sums| sums.each { |key, metrics| metrics.each { |m, v| acc[key][m] += v } } }
    acc.transform_values { |m| m.to_h.select { |_, v| v.positive? } }
  end

  def link_rows
    LinkDailyStatistic.where(link_id: @links.map(&:id)).to_h do |r|
      [[r.link_id, r.event_date, r.platform], METRICS.index_with { |m| r[m].to_i }.select { |_, v| v.positive? }]
    end
  end

  def visitor_rows
    VisitorDailyStatistic.where(visitor_id: @visitors.map(&:id)).to_h do |r|
      [[r.visitor_id, r.event_date, r.platform], METRICS.index_with { |m| r[m].to_i }.select { |_, v| v.positive? }]
    end
  end
end
