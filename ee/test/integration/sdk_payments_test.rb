require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class SdkPaymentsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects, :applications, :ios_configurations,
           :android_configurations, :devices, :visitors, :domains, :redirect_configs

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @headers = sdk_headers_for(@project, @visitor, platform: "ios")
  end

  # --- Unauthenticated ---

  test "add payment event without SDK headers returns 403 with no data" do
    post "#{SDK_PREFIX}/add_payment_event",
      params: { event_type: "buy", product_id: "com.test.premium" },
      headers: { "Host" => sdk_host }
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_not json.key?("message"), "403 must not leak success message"
  end

  # --- Add Payment Event ---

  test "add payment event with valid params creates purchase event" do
    txn_id = "sdk_txn_#{SecureRandom.hex(4)}"
    assert_difference "PurchaseEvent.count", 1 do
      post "#{SDK_PREFIX}/add_payment_event",
        params: {
          event_type: "buy",
          product_id: "com.test.premium",
          price_cents: 999,
          currency: "USD",
          transaction_id: txn_id,
          original_transaction_id: "sdk_orig_#{SecureRandom.hex(4)}",
          purchase_type: "subscription",
          store: "apple",
          date: Time.now.iso8601
        },
        headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert json["message"].present?, "must return success message"

    created = PurchaseEvent.find_by(transaction_id: txn_id)
    assert_not_nil created, "purchase event must be persisted in DB"
    assert_equal "buy", created.event_type
    assert_equal 999, created.price_cents
    assert_equal @project.id, created.project_id
  end
end
