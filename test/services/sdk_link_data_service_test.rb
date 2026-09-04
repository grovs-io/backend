require "test_helper"

class SdkLinkDataServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs

  setup do
    @project = projects(:one)
    @device = devices(:ios_device)
    @platform = Grovs::Platforms::IOS
  end

  def build_service(session_id: nil)
    SdkLinkDataService.new(
      project: @project, device: @device, platform: @platform, session_id: session_id
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
    link.define_singleton_method(:action_for) { |_device, **| action_for_result }
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

  # === session_id forwarding ===

  test "resolve_for_link forwards session_id to the OPEN event" do
    link = make_mock_link(@project)
    captured = :none

    DeviceService.stub(:match_device_by_fingerprint_request, nil) do
      EventIngestionService.stub(:log_async, ->(*_args, **kwargs) { captured = kwargs[:session_id] }) do
        build_service(session_id: "sess-abc").resolve_for_link(link, make_mock_request, "ua")
      end
    end

    assert_equal "sess-abc", captured
  end

  test "resolve_by_fingerprint forwards session_id to the OPEN event" do
    link = make_mock_link(@project)
    action = make_mock_action(link, handled: false)
    matched = devices(:android_device)
    captured = :none

    DeviceService.stub(:match_device_by_fingerprint_request, matched) do
      DeviceService.stub(:merge_visitor_events_and_device, nil) do
        ActionsService.stub(:action_for_device, action) do
          ActionsService.stub(:mark_actions_before_action_as_handled, nil) do
            EventIngestionService.stub(:log_async, ->(*_args, **kwargs) { captured = kwargs[:session_id] }) do
              build_service(session_id: "sess-xyz").resolve_by_fingerprint(make_mock_request, "ua")
            end
          end
        end
      end
    end

    assert_equal "sess-xyz", captured
  end

  test "resolve_for_link with valid gd uses clipboard device and skips fingerprint" do
    web_device = devices(:android_device)
    action = OpenStruct.new(handled: false)
    link = make_mock_link(@project, action_for_result: action)
    raw_url = "https://example.com/test?gd=#{web_device.hashid}"
    fingerprint_called = false
    merged_device = nil

    DeviceService.stub(:match_device_by_fingerprint_request, lambda { |*_args| 
      fingerprint_called = true
      nil
    }) do
      DeviceService.stub(:merge_visitor_events_and_device, ->(d, *_args) { merged_device = d }) do
        ActionsService.stub(:mark_actions_before_action_as_handled, nil) do
          EventIngestionService.stub(:log_async, nil) do
            result = build_service.resolve_for_link(link, make_mock_request, "ua", raw_url: raw_url)

            assert_equal "test data", result[:data]
          end
        end
      end
    end

    assert_equal web_device.id, merged_device.id
    assert_not fingerprint_called, "fingerprint should be skipped on clipboard match"
  end

  test "clipboard match honors the 48h window against a real hour-old action" do
    link = links(:basic_link)
    web_device = devices(:android_device)
    Action.create!(link: link, device: web_device, handled: false, created_at: 1.hour.ago)
    raw_url = "https://example.com/test?gd=#{web_device.hashid}"
    fingerprint_called = false
    merged_device = nil

    DeviceService.stub(:match_device_by_fingerprint_request, lambda { |*_args| 
      fingerprint_called = true
      nil
    }) do
      DeviceService.stub(:merge_visitor_events_and_device, ->(d, *_args) { merged_device = d }) do
        ActionsService.stub(:mark_actions_before_action_as_handled, nil) do
          EventIngestionService.stub(:log_async, nil) do
            result = build_service.resolve_for_link(link, make_mock_request, "ua", raw_url: raw_url)

            assert_equal link.data, result[:data]
          end
        end
      end
    end

    assert_equal web_device.id, merged_device.id, "hour-old action must still clipboard-match (48h window)"
    assert_not fingerprint_called
  end

  test "gd on a cross-project link is rejected before any clipboard matching" do
    web_device = devices(:android_device)
    other_link = make_mock_link(projects(:two), action_for_result: OpenStruct.new(handled: false))
    raw_url = "https://example.com/test?gd=#{web_device.hashid}"
    merge_called = false

    DeviceService.stub(:merge_visitor_events_and_device, ->(*_args) { merge_called = true }) do
      result = build_service.resolve_for_link(other_link, make_mock_request, "ua", raw_url: raw_url)

      assert_nil result[:data]
      assert_nil result[:link]
    end

    assert_not merge_called, "cross-project link must never merge the gd device"
  end

  test "clipboard match with already handled action does not log OPEN again" do
    web_device = devices(:android_device)
    action = OpenStruct.new(handled: true)
    link = make_mock_link(@project, action_for_result: action)
    raw_url = "https://example.com/test?gd=#{web_device.hashid}"
    log_called = false

    DeviceService.stub(:merge_visitor_events_and_device, nil) do
      ActionsService.stub(:mark_actions_before_action_as_handled, nil) do
        EventIngestionService.stub(:log_async, ->(*_args) { log_called = true }) do
          result = build_service.resolve_for_link(link, make_mock_request, "ua", raw_url: raw_url)

          assert_equal "test data", result[:data]
        end
      end
    end

    assert_not log_called, "repeat clipboard match must not log another OPEN"
  end

  test "resolve_for_link with gd but no action falls back to fingerprint" do
    web_device = devices(:android_device)
    link = make_mock_link(@project, action_for_result: nil)
    raw_url = "https://example.com/test?gd=#{web_device.hashid}"
    fingerprint_called = false

    DeviceService.stub(:match_device_by_fingerprint_request, lambda { |*_args| 
      fingerprint_called = true
      nil
    }) do
      EventIngestionService.stub(:log_async, nil) do
        build_service.resolve_for_link(link, make_mock_request, "ua", raw_url: raw_url)
      end
    end

    assert fingerprint_called, "fingerprint should run when gd device has no action on the link"
  end

  test "resolve_for_link with garbage gd falls back to fingerprint" do
    link = make_mock_link(@project)
    raw_url = "https://example.com/test?gd=not-a-real-hashid"
    fingerprint_called = false

    DeviceService.stub(:match_device_by_fingerprint_request, lambda { |*_args| 
      fingerprint_called = true
      nil
    }) do
      EventIngestionService.stub(:log_async, nil) do
        build_service.resolve_for_link(link, make_mock_request, "ua", raw_url: raw_url)
      end
    end

    assert fingerprint_called
  end

  test "resolve_for_link with unparseable raw_url falls back to fingerprint" do
    link = make_mock_link(@project)
    fingerprint_called = false

    DeviceService.stub(:match_device_by_fingerprint_request, lambda { |*_args| 
      fingerprint_called = true
      nil
    }) do
      EventIngestionService.stub(:log_async, nil) do
        build_service.resolve_for_link(link, make_mock_request, "ua", raw_url: "ht tp://%%bad")
      end
    end

    assert fingerprint_called
  end

  test "resolve_for_link without raw_url behaves exactly as before" do
    link = make_mock_link(@project)
    fingerprint_called = false

    DeviceService.stub(:match_device_by_fingerprint_request, lambda { |*_args| 
      fingerprint_called = true
      nil
    }) do
      EventIngestionService.stub(:log_async, nil) do
        result = build_service.resolve_for_link(link, make_mock_request, "ua")

        assert_equal "test data", result[:data]
      end
    end

    assert fingerprint_called
  end

  test "resolve_for_link sends nil session_id when the SDK omits one" do
    link = make_mock_link(@project)
    captured = :none

    DeviceService.stub(:match_device_by_fingerprint_request, nil) do
      EventIngestionService.stub(:log_async, ->(*_args, **kwargs) { captured = kwargs[:session_id] }) do
        build_service.resolve_for_link(link, make_mock_request, "ua")
      end
    end

    assert_nil captured
  end
end
