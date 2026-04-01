require "test_helper"

class SdkLinkDataServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors

  setup do
    @project = projects(:one)
    @device = devices(:ios_device)
    @platform = Grovs::Platforms::IOS
  end

  def build_service
    SdkLinkDataService.new(
      project: @project, device: @device, platform: @platform
    )
  end

  def make_mock_request
    OpenStruct.new(remote_ip: "1.2.3.4")
  end

  def make_mock_domain(project)
    OpenStruct.new(project: project)
  end

  def make_mock_link(project, should_open: true, action_for_result: nil)
    domain = make_mock_domain(project)
    link = OpenStruct.new(
      data: "test data",
      access_path: "https://example.com/test",
      tracking_dictionary: { campaign: "test" },
      domain: domain
    )
    link.define_singleton_method(:should_open_app_on_platform?) { |_platform| should_open }
    link.define_singleton_method(:action_for) { |_device| action_for_result }
    link
  end

  def make_mock_action(link, handled: false)
    OpenStruct.new(link: link, handled: handled)
  end

  # === resolve_by_fingerprint ===

  test "resolve_by_fingerprint returns nil result when no device match" do
    DeviceService.stub(:match_device_by_fingerprint_request, nil) do
      result = build_service.resolve_by_fingerprint(make_mock_request, "ua")

      assert_nil result[:data]
      assert_nil result[:link]
      assert_nil result[:tracking]
    end
  end

  test "resolve_by_fingerprint returns nil result when no action found" do
    matched = devices(:android_device)
    DeviceService.stub(:match_device_by_fingerprint_request, matched) do
      DeviceService.stub(:merge_visitor_events_and_device, nil) do
        ActionsService.stub(:action_for_device, nil) do
          result = build_service.resolve_by_fingerprint(make_mock_request, "ua")

          assert_nil result[:data]
        end
      end
    end
  end

  test "resolve_by_fingerprint returns nil when link should not open on platform" do
    link = make_mock_link(@project, should_open: false)
    action = make_mock_action(link)
    matched = devices(:android_device)

    DeviceService.stub(:match_device_by_fingerprint_request, matched) do
      DeviceService.stub(:merge_visitor_events_and_device, nil) do
        ActionsService.stub(:action_for_device, action) do
          ActionsService.stub(:mark_actions_before_action_as_handled, nil) do
            result = build_service.resolve_by_fingerprint(make_mock_request, "ua")

            assert_nil result[:data]
            assert_nil result[:link]
          end
        end
      end
    end
  end

  test "resolve_by_fingerprint returns nil result when link belongs to different project" do
    other_project = projects(:two)
    link = make_mock_link(other_project)
    action = make_mock_action(link)
    matched = devices(:android_device)

    DeviceService.stub(:match_device_by_fingerprint_request, matched) do
      DeviceService.stub(:merge_visitor_events_and_device, nil) do
        ActionsService.stub(:action_for_device, action) do
          ActionsService.stub(:mark_actions_before_action_as_handled, nil) do
            result = build_service.resolve_by_fingerprint(make_mock_request, "ua")

            assert_nil result[:data]
          end
        end
      end
    end
  end

  test "resolve_by_fingerprint returns data and logs OPEN when action not handled" do
    link = make_mock_link(@project)
    action = make_mock_action(link, handled: false)
    matched = devices(:android_device)
    log_called = false

    DeviceService.stub(:match_device_by_fingerprint_request, matched) do
      DeviceService.stub(:merge_visitor_events_and_device, nil) do
        ActionsService.stub(:action_for_device, action) do
          ActionsService.stub(:mark_actions_before_action_as_handled, nil) do
            EventIngestionService.stub(:log_async, ->(*_args) { log_called = true }) do
              result = build_service.resolve_by_fingerprint(make_mock_request, "ua")

              assert_equal "test data", result[:data]
              assert_equal "https://example.com/test", result[:link]
              assert log_called, "log_async should have been called"
            end
          end
        end
      end
    end
  end

  test "resolve_by_fingerprint returns nil data when action already handled and does not log OPEN" do
    link = make_mock_link(@project)
    action = make_mock_action(link, handled: true)
    matched = devices(:android_device)
    log_called = false

    DeviceService.stub(:match_device_by_fingerprint_request, matched) do
      DeviceService.stub(:merge_visitor_events_and_device, nil) do
        ActionsService.stub(:action_for_device, action) do
          ActionsService.stub(:mark_actions_before_action_as_handled, nil) do
            EventIngestionService.stub(:log_async, ->(*_args) { log_called = true }) do
              result = build_service.resolve_by_fingerprint(make_mock_request, "ua")

              assert_nil result[:data]
              assert_equal "https://example.com/test", result[:link]
              assert_not log_called, "log_async should NOT have been called"
            end
          end
        end
      end
    end
  end

  # === resolve_for_link ===

  test "resolve_for_link with nil link delegates to resolve_by_fingerprint" do
    DeviceService.stub(:match_device_by_fingerprint_request, nil) do
      result = build_service.resolve_for_link(nil, make_mock_request, "ua")

      assert_nil result[:data]
    end
  end

  test "resolve_for_link with wrong project link returns nil result" do
    other_project = projects(:two)
    link = make_mock_link(other_project)

    result = build_service.resolve_for_link(link, make_mock_request, "ua")

    assert_nil result[:data]
    assert_nil result[:link]
  end

  test "resolve_for_link with no device match logs OPEN" do
    link = make_mock_link(@project)
    log_called = false

    DeviceService.stub(:match_device_by_fingerprint_request, nil) do
      EventIngestionService.stub(:log_async, ->(*_args) { log_called = true }) do
        result = build_service.resolve_for_link(link, make_mock_request, "ua")

        assert_equal "test data", result[:data]
        assert_equal "https://example.com/test", result[:link]
        assert log_called, "log_async should have been called"
      end
    end
  end

  test "resolve_for_link with matched device and action found marks action" do
    action = OpenStruct.new(handled: false)
    link = make_mock_link(@project, action_for_result: action)
    matched = devices(:android_device)
    log_called = false
    mark_called = false

    DeviceService.stub(:match_device_by_fingerprint_request, matched) do
      DeviceService.stub(:merge_visitor_events_and_device, nil) do
        ActionsService.stub(:mark_actions_before_action_as_handled, ->(*_args) { mark_called = true }) do
          EventIngestionService.stub(:log_async, ->(*_args) { log_called = true }) do
            result = build_service.resolve_for_link(link, make_mock_request, "ua")

            assert_equal "test data", result[:data]
            assert mark_called, "mark_actions_before_action_as_handled should have been called"
            assert log_called, "log_async should have been called"
          end
        end
      end
    end
  end

  test "resolve_for_link with matched device and handled action does not log OPEN" do
    action = OpenStruct.new(handled: true)
    link = make_mock_link(@project, action_for_result: action)
    matched = devices(:android_device)
    log_called = false

    DeviceService.stub(:match_device_by_fingerprint_request, matched) do
      DeviceService.stub(:merge_visitor_events_and_device, nil) do
        ActionsService.stub(:mark_actions_before_action_as_handled, nil) do
          EventIngestionService.stub(:log_async, ->(*_args) { log_called = true }) do
            result = build_service.resolve_for_link(link, make_mock_request, "ua")

            assert_equal "test data", result[:data]
            assert_not log_called, "log_async should NOT have been called"
          end
        end
      end
    end
  end

  test "resolve_for_link with matched device but no action for link still logs OPEN" do
    link = make_mock_link(@project, action_for_result: nil)
    matched = devices(:android_device)
    log_called = false

    DeviceService.stub(:match_device_by_fingerprint_request, matched) do
      DeviceService.stub(:merge_visitor_events_and_device, nil) do
        EventIngestionService.stub(:log_async, ->(*_args) { log_called = true }) do
          result = build_service.resolve_for_link(link, make_mock_request, "ua")

          assert_equal "test data", result[:data]
          assert log_called, "log_async should have been called"
        end
      end
    end
  end
end
