require "test_helper"

class FailedPurchaseJobCallbacksTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events, :iap_webhook_messages

  # === ProcessPurchaseEventJob ===

  test "ProcessPurchaseEventJob persists failure with purchase_event and project linkage" do
    event = purchase_events(:buy_event)
    job_hash = { 'class' => 'ProcessPurchaseEventJob', 'args' => [event.id] }
    exception = RuntimeError.new("currency conversion failed")
    exception.set_backtrace(["app/jobs/process_purchase_event_job.rb:96", "app/services/helpers/currency.rb:12"])

    assert_difference "FailedPurchaseJob.count", 1 do
      ProcessPurchaseEventJob.sidekiq_retries_exhausted_block.call(job_hash, exception)
    end

    failed = FailedPurchaseJob.last
    assert_equal "ProcessPurchaseEventJob", failed.job_class
    assert_equal [event.id], failed.arguments
    assert_equal "RuntimeError", failed.error_class
    assert_equal "currency conversion failed", failed.error_message
    assert_includes failed.backtrace, "currency.rb:12"
    assert_equal event.id, failed.purchase_event_id
    assert_equal event.project_id, failed.project_id
    assert_equal "pending", failed.status
  end

  # === ValidatePurchaseEventJob ===

  test "ValidatePurchaseEventJob preserves multi-arg job arguments" do
    event = purchase_events(:buy_event)
    job_hash = { 'class' => 'ValidatePurchaseEventJob', 'args' => [event.id, Grovs::Platforms::IOS] }
    exception = RuntimeError.new("Apple API timeout")
    exception.set_backtrace([])

    ProcessGoogleNotificationJob.sidekiq_retries_exhausted_block # warm

    assert_difference "FailedPurchaseJob.count", 1 do
      ValidatePurchaseEventJob.sidekiq_retries_exhausted_block.call(job_hash, exception)
    end

    failed = FailedPurchaseJob.last
    assert_equal [event.id, Grovs::Platforms::IOS], failed.arguments
    assert_equal event.project_id, failed.project_id
  end

  # === ProcessGoogleNotificationJob ===

  test "ProcessGoogleNotificationJob sets nil purchase_event_id and resolves project from webhook message" do
    webhook_msg = iap_webhook_messages(:google_webhook)
    job_hash = { 'class' => 'ProcessGoogleNotificationJob', 'args' => [webhook_msg.id, { "data" => "test" }, instances(:one).id] }
    exception = RuntimeError.new("Google API error")
    exception.set_backtrace([])

    assert_difference "FailedPurchaseJob.count", 1 do
      ProcessGoogleNotificationJob.sidekiq_retries_exhausted_block.call(job_hash, exception)
    end

    failed = FailedPurchaseJob.last
    assert_nil failed.purchase_event_id
    assert_equal webhook_msg.project_id, failed.project_id
    assert_equal [webhook_msg.id, { "data" => "test" }, instances(:one).id], failed.arguments
  end

  # === ReattributePurchaseJob ===

  test "ReattributePurchaseJob records failure like other purchase jobs" do
    event = purchase_events(:buy_event)
    job_hash = { 'class' => 'ReattributePurchaseJob', 'args' => [event.id] }
    exception = RuntimeError.new("device not found")
    exception.set_backtrace([])

    assert_difference "FailedPurchaseJob.count", 1 do
      ReattributePurchaseJob.sidekiq_retries_exhausted_block.call(job_hash, exception)
    end

    failed = FailedPurchaseJob.last
    assert_equal event.id, failed.purchase_event_id
    assert_equal event.project_id, failed.project_id
  end

  # === Edge cases ===

  test "falls back to job hash error fields when exception is nil" do
    event = purchase_events(:buy_event)
    job_hash = {
      'class' => 'ProcessPurchaseEventJob',
      'args' => [event.id],
      'error_class' => 'Net::ReadTimeout',
      'error_message' => 'execution expired'
    }

    assert_difference "FailedPurchaseJob.count", 1 do
      ProcessPurchaseEventJob.sidekiq_retries_exhausted_block.call(job_hash, nil)
    end

    failed = FailedPurchaseJob.last
    assert_equal "Net::ReadTimeout", failed.error_class
    assert_equal "execution expired", failed.error_message
  end

  test "records failure even when purchase_event no longer exists" do
    job_hash = { 'class' => 'ProcessPurchaseEventJob', 'args' => [999999] }
    exception = RuntimeError.new("not found")
    exception.set_backtrace([])

    assert_difference "FailedPurchaseJob.count", 1 do
      ProcessPurchaseEventJob.sidekiq_retries_exhausted_block.call(job_hash, exception)
    end

    failed = FailedPurchaseJob.last
    assert_equal 999999, failed.purchase_event_id
    assert_nil failed.project_id, "project_id should be nil when purchase event is gone"
  end
end
