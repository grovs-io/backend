require "test_helper"
require "sidekiq/testing"

class TenantIsolationConcurrencyTest < ActiveSupport::TestCase
  include ConcurrencyHelper
  include ClickhouseTestHelper

  self.use_transactional_tests = false # both tenants' requests and workers commit on their own connections

  fixtures :instances, :projects, :domains, :redirect_configs, :redirects, :applications

  Request = Struct.new(:ip, :remote_ip)

  setup do
    skip_unless_clickhouse!
    ensure_pool!
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
    @tenants = [projects(:one), projects(:two)]
    @request = Request.new("198.51.100.77", "192.0.2.77")
    @devices = []
    @links = []
    redis_del_matching(BatchEventProcessorJob::REDIS_KEY)
  end

  teardown do
    next unless concurrency_enabled?

    Sidekiq::Worker.clear_all
    ids = @devices.map(&:id)
    visitor_ids = Visitor.where(device_id: ids).pluck(:id)
    Event.where(device_id: ids).delete_all
    Action.where(device_id: ids).delete_all
    LinkDailyStatistic.where(link_id: @links.map(&:id)).delete_all
    VisitorDailyStatistic.where(visitor_id: visitor_ids).delete_all
    VisitorLastVisit.where(visitor_id: visitor_ids).delete_all
    DeviceLastSeen.where(device_id: ids).delete_all
    Visitor.where(id: visitor_ids).delete_all
    Link.where(id: @links.map(&:id)).delete_all
    Device.where(id: ids).delete_all
    redis_del_matching(BatchEventProcessorJob::REDIS_KEY, "#{BatchEventProcessorJob::PROCESSING_KEY_PREFIX}:*",
                       "#{BatchEventProcessorJob::HEARTBEAT_PREFIX}:*", "fp:*", "di:*", "#{MergeVisitorEventsJob::PAIR_PREFIX}:*")
  end

  # Catches: fingerprint lookups or batch stats not scoped by project (one tenant's click credited to another).
  test "two tenants clicking and installing at once from one NAT with identical phones never cross-attribute" do
    pairs = scaled(6)
    clicks = {}
    installers = Array.new(pairs) { |i| device(user_agent(i), app: true) }
    @tenants.each do |project|
      domain = Domain.find_by!(project_id: project.id)
      pairs.times do |i|
        link = Link.create!(domain: domain, redirect_config: redirect_configs(:one), path: "conc-tenant-#{SecureRandom.hex(5)}",
                            generated_from_platform: "ios", data: [{ "tenant" => project.id }]).tap { |l| @links << l }
        web = device(user_agent(i))
        clicks[[project.id, i]] = { link: link, web: web }
        Visitor.create!(project: project, device: installers[i])
      end
    end

    jobs = clicks.keys.shuffle
    run_concurrently do |t|
      jobs.select.with_index { |_, j| j % THREADS == t }.each do |project_id, i|
        ActionsService.create_if_needed(clicks[[project_id, i]][:web], clicks[[project_id, i]][:link])
        FingerprintingService.cache_device(clicks[[project_id, i]][:web], @request, project_id)
      end
    end
    results = run_concurrently do |t|
      jobs.select.with_index { |_, j| j % THREADS == t }.to_h do |project_id, i|
        project = @tenants.find { |p| p.id == project_id }
        [[project_id, i], SdkLinkDataService.new(project: project, device: installers[i], platform: Grovs::Platforms::IOS)
                                            .resolve_by_fingerprint(@request, user_agent(i))]
      end
    end.reduce({}, :merge)

    expected = clicks.transform_values { |c| c[:link].access_path }
    assert_equal expected, results.transform_values { |r| r[:link] }, "each install credits exactly its own tenant's click"
    merges = MergeVisitorEventsJob.jobs.map { |j| j["args"] }
    web_owner = clicks.to_h { |(project_id, _), c| [c[:web].id, project_id] }
    assert_equal clicks.size, merges.size
    merges.each { |from, _to, project_id| assert_equal web_owner.fetch(from), project_id, "merge crosses tenants" }

    drain_batch_workers
    assert_stats_stay_in_tenant(clicks, installers)
  end

  private

  def user_agent(index)
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.#{100 + index} (KHTML, like Gecko) " \
      "Version/17.4 Mobile/15E148 Safari/604.1"
  end

  def device(user_agent, app: false)
    Device.create!(user_agent: app ? "ConcTenantApp/1" : user_agent, ip: @request.ip, remote_ip: @request.remote_ip,
                   platform: "ios", vendor: "conc-tenant-#{SecureRandom.hex(6)}").tap { |d| @devices << d }
  end

  def drain_batch_workers
    statuses = run_concurrently do |i|
      job = BatchEventProcessorJob.new
      job.jid = "conc-tenant-#{i}-#{SecureRandom.hex(3)}"
      done = []
      while (raw = job.send(:pop_events, 3)).any?
        done << job.send(:process_batch, raw)
        break unless done.last == :success
      end
      done
    end.flatten
    assert_equal [:success], statuses.uniq
  end

  def assert_stats_stay_in_tenant(clicks, installers)
    link_project = clicks.to_h { |(project_id, _), c| [c[:link].id, project_id] }
    opens = LinkDailyStatistic.where(link_id: link_project.keys).to_h { |r| [r.link_id, [r.project_id, r.opens]] }
    assert_equal link_project.transform_values { |p| [p, 1] }, opens, "every link: one open, booked to its own tenant"

    visitor_rows = VisitorDailyStatistic.joins(:visitor).where(visitors: { device_id: installers.map(&:id) })
                                        .pluck("visitor_daily_statistics.project_id", "visitors.project_id", :opens)
    assert_equal clicks.size, visitor_rows.size
    visitor_rows.each { |row_project, visitor_project, n| assert_equal [visitor_project, 1], [row_project, n] }

    events = Event.where(device_id: installers.map(&:id), event: Grovs::Events::OPEN).pluck(:project_id, :link_id)
    assert_equal link_project.map { |link_id, project_id| [project_id, link_id] }.sort, events.sort
  end
end
