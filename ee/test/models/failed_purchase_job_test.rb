require "test_helper"

class FailedPurchaseJobTest < ActiveSupport::TestCase
  fixtures :projects, :purchase_events

  # === retry! ===

  test "retry! re-enqueues the original job class with original args and marks retried" do
    event = purchase_events(:buy_event)
    failed = FailedPurchaseJob.create!(
      job_class: "ProcessPurchaseEventJob",
      arguments: [event.id],
      status: "pending",
      failed_at: Time.current
    )

    enqueued_args = nil
    ProcessPurchaseEventJob.stub(:perform_async, ->(*args) { enqueued_args = args }) do
      failed.retry!
    end

    assert_equal [event.id], enqueued_args, "Should enqueue with original arguments"
    assert_equal "retried", failed.reload.status
    assert_not_nil failed.retried_at
  end

  test "retry! works for ValidatePurchaseEventJob with multi-arg jobs" do
    failed = FailedPurchaseJob.create!(
      job_class: "ValidatePurchaseEventJob",
      arguments: [42, Grovs::Platforms::IOS],
      status: "pending",
      failed_at: Time.current
    )

    enqueued_args = nil
    ValidatePurchaseEventJob.stub(:perform_async, ->(*args) { enqueued_args = args }) do
      failed.retry!
    end

    assert_equal [42, Grovs::Platforms::IOS], enqueued_args
  end

  test "retry! raises for non-pending status" do
    %w[retried discarded].each do |status|
      failed = FailedPurchaseJob.create!(
        job_class: "ProcessPurchaseEventJob",
        arguments: [1],
        status: status,
        failed_at: 1.hour.ago,
        retried_at: status == "retried" ? Time.current : nil
      )

      error = assert_raises(RuntimeError) { failed.retry! }
      assert_match(/Cannot retry a #{status} job/, error.message)
    end
  end

  # === scope ===

  test "pending scope excludes retried and discarded" do
    pending_job = FailedPurchaseJob.create!(
      job_class: "ProcessPurchaseEventJob", arguments: [1],
      status: "pending", failed_at: Time.current
    )
    FailedPurchaseJob.create!(
      job_class: "ProcessPurchaseEventJob", arguments: [2],
      status: "retried", failed_at: 1.hour.ago, retried_at: Time.current
    )
    FailedPurchaseJob.create!(
      job_class: "ProcessPurchaseEventJob", arguments: [3],
      status: "discarded", failed_at: 1.hour.ago
    )

    results = FailedPurchaseJob.pending.to_a
    assert_equal [pending_job], results
  end

  # === status validation (guards retry! logic) ===

  test "rejects invalid status values" do
    job = FailedPurchaseJob.new(
      job_class: "ProcessPurchaseEventJob", arguments: [1],
      status: "completed", failed_at: Time.current
    )
    assert_not job.valid?
    assert job.errors[:status].any?
  end
end
