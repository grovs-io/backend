require "test_helper"

class ProcessGoogleNotificationJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  setup do
    @job = ProcessGoogleNotificationJob.new
    @instance = instances(:one)
  end

  # --- Core flow ---
  # GoogleIapService calls Google Play APIs, so stub is justified.

  test "calls GoogleIapService.handle_notification with correct arguments" do
    msg = IapWebhookMessage.create!(
      instance_id: @instance.id, source: "google",
      payload: '{"test": true}', notification_type: "SUBSCRIPTION_PURCHASED"
    )
    parsed_data = { "packageName" => "com.test.app", "subscriptionNotification" => { "subscriptionId" => "sub_1" } }
    received_args = nil

    google_mock = GoogleIapService.new
    google_mock.define_singleton_method(:handle_notification) do |data, inst, webhook_msg|
      received_args = { data: data, instance_id: inst.id, msg_id: webhook_msg.id }
    end

    GoogleIapService.stub(:new, google_mock) do
      @job.perform(msg.id, parsed_data, @instance.id)
    end

    assert_not_nil received_args, "Should call handle_notification"
    assert_equal parsed_data, received_args[:data]
    assert_equal @instance.id, received_args[:instance_id]
    assert_equal msg.id, received_args[:msg_id]
  end

  # --- Guard clauses ---

  test "returns early when instance not found" do
    msg = IapWebhookMessage.create!(
      instance_id: @instance.id, source: "google",
      payload: '{}', notification_type: "TEST"
    )
    called = false
    google_mock = GoogleIapService.new
    google_mock.define_singleton_method(:handle_notification) { |*_| called = true }

    GoogleIapService.stub(:new, google_mock) do
      @job.perform(msg.id, {}, 999999)
    end

    assert_not called, "Should NOT call GoogleIapService when instance missing"
  end

  test "returns early when webhook message not found" do
    called = false
    google_mock = GoogleIapService.new
    google_mock.define_singleton_method(:handle_notification) { |*_| called = true }

    GoogleIapService.stub(:new, google_mock) do
      @job.perform(999999, {}, @instance.id)
    end

    assert_not called, "Should NOT call GoogleIapService when message missing"
  end

  # --- DLQ handler ---

  test "DLQ handler creates FailedPurchaseJob with project_id from webhook message" do
    msg = IapWebhookMessage.create!(
      instance_id: @instance.id, source: "google",
      payload: '{}', notification_type: "SUBSCRIPTION_PURCHASED",
      project_id: projects(:one).id
    )

    job_hash = {
      'class' => 'ProcessGoogleNotificationJob',
      'args' => [msg.id, {}, @instance.id],
      'error_class' => 'RuntimeError',
      'error_message' => 'google API timeout'
    }

    assert_difference "FailedPurchaseJob.count", 1 do
      ProcessGoogleNotificationJob.sidekiq_retries_exhausted_block.call(job_hash, nil)
    end

    failed = FailedPurchaseJob.last
    assert_equal 'ProcessGoogleNotificationJob', failed.job_class
    assert_equal projects(:one).id, failed.project_id
    assert_equal 'google API timeout', failed.error_message
  end
end
