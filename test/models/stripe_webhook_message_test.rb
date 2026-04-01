require "test_helper"

class StripeWebhookMessageTest < ActiveSupport::TestCase
  fixtures :stripe_webhook_messages

  # === creation ===

  test "can be created with data and message_type" do
    msg = StripeWebhookMessage.new(
      data: { "type" => "invoice.paid", "id" => "evt_new" },
      message_type: "invoice.paid"
    )
    assert msg.save
    assert_equal "invoice.paid", msg.reload.message_type
  end

  test "can be created with nil data" do
    msg = StripeWebhookMessage.new(data: nil, message_type: "unknown")
    assert msg.save
  end

  test "fixture loads correctly" do
    msg = stripe_webhook_messages(:invoice_paid)
    assert_equal "invoice.paid", msg.message_type
    assert_not_nil msg.data
  end

  test "data stores JSON content" do
    msg = stripe_webhook_messages(:subscription_updated)
    assert_equal "customer.subscription.updated", msg.message_type
    assert_not_nil msg.data
    # jsonb column can be a Hash or String depending on driver
    data = msg.data.is_a?(String) ? JSON.parse(msg.data) : msg.data
    assert_equal "evt_002", data["id"]
  end
end
