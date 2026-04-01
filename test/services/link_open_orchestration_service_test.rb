require "test_helper"

class LinkOpenOrchestrationServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :links, :domains, :redirect_configs

  setup do
    @project = projects(:one)
    @device  = devices(:ios_device)
    @link    = links(:basic_link)
    @request = OpenStruct.new(remote_ip: "1.2.3.4", ip: "1.2.3.4", user_agent: "Test/1.0")
    @project.instance.update_column(:quota_exceeded, false)
  end

  # ---------------------------------------------------------------------------
  # Quota gate
  # ---------------------------------------------------------------------------

  test "returns :quota_exceeded and does nothing when instance quota is exceeded" do
    @project.instance.update_column(:quota_exceeded, true)
    side_effects = []

    EventIngestionService.stub(:log_async, ->(*_) { side_effects << :log }) do
      ActionsService.stub(:create_if_needed, ->(*_) { side_effects << :action }) do
        FingerprintingService.stub(:cache_device, ->(*_) { side_effects << :fp }) do
          result = call_service
          assert_equal :quota_exceeded, result
        end
      end
    end

    assert_empty side_effects, "No side effects should fire when quota exceeded"
  end

  # ---------------------------------------------------------------------------
  # VIEW event logging
  # ---------------------------------------------------------------------------

  test "logs VIEW event with correct arguments when should_log_view? is true" do
    logged_args = nil

    EventIngestionService.stub(:log_async, ->(*args) { logged_args = args }) do
      ActionsService.stub(:create_if_needed, nil) do
        FingerprintingService.stub(:cache_device, nil) do
          LinkDisplayService.stub(:should_log_view?, true) do
            call_service
          end
        end
      end
    end

    assert_not_nil logged_args, "log_async should have been called"
    assert_equal Grovs::Events::VIEW, logged_args[0]
    assert_equal @project, logged_args[1]
    assert_equal @device, logged_args[2]
    assert_nil logged_args[3] # data
    assert_equal @link, logged_args[4]
  end

  test "skips VIEW event when should_log_view? is false" do
    logged = false

    EventIngestionService.stub(:log_async, ->(*_) { logged = true }) do
      ActionsService.stub(:create_if_needed, nil) do
        FingerprintingService.stub(:cache_device, nil) do
          LinkDisplayService.stub(:should_log_view?, false) do
            call_service
          end
        end
      end
    end

    assert_not logged
  end

  # ---------------------------------------------------------------------------
  # Side effects always fire (when not quota-exceeded)
  # ---------------------------------------------------------------------------

  test "creates action with correct device and link" do
    action_args = nil

    EventIngestionService.stub(:log_async, nil) do
      ActionsService.stub(:create_if_needed, ->(d, l) { action_args = [d, l] }) do
        FingerprintingService.stub(:cache_device, nil) do
          call_service
        end
      end
    end

    assert_equal [@device, @link], action_args
  end

  test "caches fingerprint with correct device, request, and project_id" do
    fp_args = nil

    EventIngestionService.stub(:log_async, nil) do
      ActionsService.stub(:create_if_needed, nil) do
        FingerprintingService.stub(:cache_device, ->(d, r, pid) { fp_args = [d, r, pid] }) do
          call_service
        end
      end
    end

    assert_equal @device, fp_args[0]
    assert_equal @request, fp_args[1]
    assert_equal @project.id, fp_args[2]
  end

  test "returns :ok on success" do
    EventIngestionService.stub(:log_async, nil) do
      ActionsService.stub(:create_if_needed, nil) do
        FingerprintingService.stub(:cache_device, nil) do
          assert_equal :ok, call_service
        end
      end
    end
  end

  private

  def call_service(go_to_fallback: nil, grovs_redirect: nil)
    LinkOpenOrchestrationService.call(
      project: @project, device: @device, link: @link,
      request: @request, go_to_fallback: go_to_fallback, grovs_redirect: grovs_redirect
    )
  end
end
