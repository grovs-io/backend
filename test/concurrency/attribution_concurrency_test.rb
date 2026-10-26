require "test_helper"
require "sidekiq/testing"

class AttributionConcurrencyTest < ActiveSupport::TestCase
  include ConcurrencyHelper

  self.use_transactional_tests = false # racing requests read each other's committed actions

  fixtures :instances, :projects, :domains, :redirect_configs, :redirects, :applications

  IOS_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) " \
           "Version/17.4 Mobile/15E148 Safari/604.1".freeze
  Request = Struct.new(:ip, :remote_ip)

  setup do
    ensure_pool!
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
    @project = projects(:one)
    @link = Link.create!(domain: domains(:one), redirect_config: redirect_configs(:one),
                         path: "conc-attr-#{SecureRandom.hex(5)}", generated_from_platform: "ios", data: [{ "k" => "v" }])
    @devices = []
    redis_del_matching(BatchEventProcessorJob::REDIS_KEY)
  end

  teardown do
    next unless concurrency_enabled?

    Sidekiq::Worker.clear_all
    ids = @devices.map(&:id)
    Action.where(device_id: ids).delete_all
    VisitorLastVisit.where(link_id: @link&.id).delete_all
    DeviceLastSeen.where(device_id: ids).delete_all
    Visitor.where(device_id: ids).delete_all
    Link.where(id: @link&.id).delete_all
    Device.where(id: ids).delete_all
    redis_del_matching(BatchEventProcessorJob::REDIS_KEY, "fp:*", "di:*", "#{MergeVisitorEventsJob::PAIR_PREFIX}:*")
  end

  # Catches: the fingerprint match read and its cache removal not being atomic (one click, many credits).
  test "installs racing for one fingerprinted click: at most one is credited" do
    rounds = scaled(5)
    over_credited = []

    rounds.times do |round|
      request = Request.new("198.51.100.#{round + 1}", "192.0.2.#{round + 1}")
      click_from(device(IOS_UA, request), request)
      installers = Array.new(THREADS) { device("ConcApp/1", request, visitor: true) }
      opens_before = queued_opens.size

      results = run_concurrently do |i|
        SdkLinkDataService.new(project: @project, device: installers[i], platform: Grovs::Platforms::IOS)
                          .resolve_by_fingerprint(request, IOS_UA)
      end

      credited = results.count { |r| r[:link].present? }
      opens = queued_opens.size - opens_before
      over_credited << { round: round, credited: credited, opens: opens } if credited > 1 || opens > 1
    end

    assert_empty over_credited, "one click credited to several installs (data delivered / OPEN counted per install)"
  end

  # Catches: ActionsService.create_if_needed check-then-create letting a burst of opens insert duplicate actions.
  test "concurrent link opens for one device and link record a single pending action" do
    skip_known_bug!("ActionsService.create_if_needed is check-then-create with no lock or unique index")
    rounds = scaled(5)
    duplicated = []

    rounds.times do |round|
      request = Request.new("198.51.100.#{100 + round}", "192.0.2.#{100 + round}")
      web = device(IOS_UA, request)
      run_concurrently { ActionsService.create_if_needed(web, @link) }
      count = Action.where(device_id: web.id, link_id: @link.id, handled: false).count
      duplicated << { round: round, actions: count } if count != 1
    end

    assert_empty duplicated, "one device+link burst left more than one pending action"
  end

  private

  def device(user_agent, request, visitor: false)
    Device.create!(user_agent: user_agent, ip: request.ip, remote_ip: request.remote_ip, platform: "ios",
                   vendor: "conc-attr-#{SecureRandom.hex(6)}").tap do |d|
      @devices << d
      Visitor.create!(project: @project, device: d) if visitor
    end
  end

  def click_from(web, request)
    ActionsService.create_if_needed(web, @link)
    FingerprintingService.cache_device(web, request, @project.id)
  end

  def queued_opens
    REDIS.with { |c| c.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1) }
         .map { |raw| JSON.parse(raw) }
         .select { |e| e["type"] == Grovs::Events::OPEN && e["link_id"] == @link.id }
  end
end
