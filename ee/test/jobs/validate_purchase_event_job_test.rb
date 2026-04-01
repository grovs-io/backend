require "test_helper"

class ValidatePurchaseEventJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events

  setup do
    @job = ValidatePurchaseEventJob.new
    @project = projects(:one)
  end

  # --- Core flow: validated → enqueue, not validated → skip ---
  # PurchaseValidationService calls Apple/Google APIs, so stub is justified.

  test "enqueues ProcessPurchaseEventJob when validation succeeds" do
    event = purchase_events(:unprocessed_buy)
    enqueued_id = nil

    PurchaseValidationService.stub(:validate, ->(_event, _platform) { true }) do
      ProcessPurchaseEventJob.stub(:perform_async, ->(id) { enqueued_id = id }) do
        @job.perform(event.id, Grovs::Platforms::IOS)
      end
    end

    assert_equal event.id, enqueued_id, "Should enqueue ProcessPurchaseEventJob with event ID"
  end

  test "does NOT enqueue ProcessPurchaseEventJob when validation fails" do
    event = purchase_events(:unprocessed_buy)
    enqueued = false

    PurchaseValidationService.stub(:validate, ->(_event, _platform) { false }) do
      ProcessPurchaseEventJob.stub(:perform_async, ->(_id) { enqueued = true }) do
        @job.perform(event.id, Grovs::Platforms::IOS)
      end
    end

    assert_not enqueued, "Should NOT enqueue when validation fails"
  end

  # --- Guard clause ---

  test "returns early for nonexistent event — no validation attempted" do
    validation_called = false

    PurchaseValidationService.stub(:validate, lambda { |*_| 
      validation_called = true
      false
    }) do
      @job.perform(999999, Grovs::Platforms::IOS)
    end

    assert_not validation_called, "Should not call validation for missing event"
  end

  # --- DLQ handler ---

  test "DLQ handler creates FailedPurchaseJob with event and project info" do
    event = purchase_events(:buy_event)

    job_hash = {
      'class' => 'ValidatePurchaseEventJob',
      'args' => [event.id, Grovs::Platforms::IOS],
      'error_class' => 'RuntimeError',
      'error_message' => 'validation timeout'
    }

    assert_difference "FailedPurchaseJob.count", 1 do
      ValidatePurchaseEventJob.sidekiq_retries_exhausted_block.call(job_hash, nil)
    end

    failed = FailedPurchaseJob.last
    assert_equal 'ValidatePurchaseEventJob', failed.job_class
    assert_equal event.id, failed.purchase_event_id
    assert_equal @project.id, failed.project_id
    assert_equal 'validation timeout', failed.error_message
  end

  test "DLQ handler handles nil event_id gracefully" do
    job_hash = {
      'class' => 'ValidatePurchaseEventJob',
      'args' => [nil, Grovs::Platforms::IOS],
      'error_class' => 'RuntimeError',
      'error_message' => 'nil event'
    }

    assert_difference "FailedPurchaseJob.count", 1 do
      ValidatePurchaseEventJob.sidekiq_retries_exhausted_block.call(job_hash, nil)
    end

    failed = FailedPurchaseJob.last
    assert_nil failed.purchase_event_id
    assert_nil failed.project_id
  end
end
