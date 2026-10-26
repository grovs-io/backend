require "test_helper"

class SdkLinkActionMergeTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs,
           :applications, :redirects

  setup do
    @project = projects(:one)
    @browser = devices(:web_device)
    @app = devices(:ios_device)
    @link = links(:basic_link)
    Visitor.create!(device: @browser, project: @project)
    @request = OpenStruct.new(ip: "198.18.0.1", remote_ip: "203.0.113.1")
    @service = SdkLinkDataService.new(
      project: @project, device: @app, platform: Grovs::Platforms::IOS, session_id: "action-id-regression"
    )
    @pair_key = "#{MergeVisitorEventsJob::PAIR_PREFIX}:#{[@browser.id, @app.id].sort.join(':')}:#{@project.id}"
    REDIS.del(@pair_key)
    FingerprintingService.cache_device(@browser, @request, @project.id)
  end

  teardown do
    REDIS.del(@pair_key)
    FingerprintingService.remove_device_from_cache_by_id(@browser.id, @project.id)
  end

  %i[fingerprint explicit_link clipboard].each do |resolution|
    %i[immediate delayed rejected accepted_but_timeout].each do |delivery|
      test "#{resolution} consumes captured IDs with #{delivery} merge delivery" do
        older = Action.create!(device: @browser, link: @link, handled: false, created_at: 2.minutes.ago)
        selected = Action.create!(device: @browser, link: @link, handled: false, created_at: 1.minute.ago)
        target = Action.create!(device: @app, link: @link, handled: false, created_at: 3.minutes.ago)
        target_before = target.attributes
        later = nil
        queued = []
        opens = []
        enqueue = lambda do |*args|
          later = Action.create!(device: @browser, link: @link, handled: false)
          raise Redis::CannotConnectError, "queue rejected job" if delivery == :rejected

          if delivery == :delayed
            queued << args
          else
            MergeVisitorEventsJob.new.perform(*args)
          end
          raise Redis::CannotConnectError, "queue acknowledgement lost" if delivery == :accepted_but_timeout

          "merge-job-id"
        end

        MergeVisitorClickhouseFoldJob.stub(:perform_async, nil) do
          MergeVisitorEventsJob.stub(:perform_async, enqueue) do
            EventIngestionService.stub(:log_async, ->(*args, **kwargs) { opens << [args, kwargs] }) do
              if %i[rejected accepted_but_timeout].include?(delivery)
                assert_raises(Redis::CannotConnectError) { resolve(resolution) }
                assert_not selected.reload.handled
                assert_not older.reload.handled
                assert_empty opens
              else
                result = resolve(resolution)
                queued.each { |args| MergeVisitorEventsJob.new.perform(*args) }
                assert_equal @link.data, result[:data]
                assert_equal @link.access_path, result[:link]
                assert_equal @link.tracking_dictionary, result[:tracking]
                assert selected.reload.handled
                assert older.reload.handled
                assert_equal 1, opens.size
                assert_equal Grovs::Events::OPEN, opens.first[0].first
                assert_equal @app.id, opens.first[0][2].id
                assert_equal "action-id-regression", opens.first[1][:session_id]
              end
            end
          end
        end

        expected_device = delivery == :rejected ? @browser.id : @app.id
        assert_equal expected_device, selected.reload.device_id
        assert_equal expected_device, older.reload.device_id
        assert_equal target_before, target.reload.attributes
        assert_not later.reload.handled, "clicks outside the captured set must not be consumed"
      end
    end
  end

  test "an empty captured set never consumes actions discovered after a merge" do
    selected = Action.create!(device: @browser, link: @link, handled: true)
    ids = ActionsService.action_ids_before_action(selected)
    assert_empty ids
    later = Action.create!(device: @browser, link: @link, handled: false, created_at: 1.minute.ago)

    ActionsService.mark_actions_before_action_as_handled(selected, action_ids: ids)

    assert_not later.reload.handled
  end

  private

  def resolve(resolution)
    return @service.resolve_by_fingerprint(@request, @browser.user_agent) if resolution == :fingerprint

    raw_url = "#{@link.access_path}?gd=#{@browser.hashid}" if resolution == :clipboard
    @service.resolve_for_link(@link, @request, @browser.user_agent, raw_url: raw_url)
  end
end
