require "test_helper"

class RpushFcmThrottleRetryTest < ActiveSupport::TestCase
  Response = Struct.new(:code, :header, :body)

  class RecordingBatch
    attr_reader :retryable, :failed

    def initialize = (@retryable = []) && (@failed = [])
    def mark_retryable(notification, at) = @retryable << [notification.id, at]
    def mark_failed(notification, *) = @failed << notification.id
    def notification_processed; end
  end

  def deliver(status, retries: 0, retry_after: nil)
    app = Rpush::Fcm::App.new(name: "a", firebase_project_id: "p", json_key: "{}")
    notification = Rpush::Fcm::Notification.new(id: 1, retries: retries)
    batch = RecordingBatch.new
    delivery = Rpush::Daemon::Fcm::Delivery.new(app, nil, notification, batch)
    body = { error: { status: "RESOURCE_EXHAUSTED", message: "Quota exceeded." } }.to_json
    delivery.send(:handle_response, Response.new(status.to_s, { "retry-after" => retry_after }, body))
    batch
  rescue Rpush::DeliveryError
    batch
  end

  test "a throttled push is retried, after Retry-After when FCM sends one" do
    batch = deliver(429, retry_after: "30")
    assert_equal [1], batch.retryable.map(&:first)
    assert_in_delta 30, batch.retryable.first.last - Time.now, 2
  end

  test "a throttled push backs off exponentially without Retry-After" do
    batch = deliver(429, retries: 3)
    assert_in_delta 16, batch.retryable.first.last - Time.now, 2
  end

  test "it gives up after the retry budget, as rpush did before" do
    assert_empty deliver(429, retries: RpushFcmThrottleRetry::MAX_RETRIES).retryable
  end

  test "other statuses keep rpush's handling" do
    assert_empty deliver(404).retryable
  end
end
