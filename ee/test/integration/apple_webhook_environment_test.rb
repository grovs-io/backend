require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class AppleWebhookEnvironmentTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects, :applications, :ios_configurations

  setup do
    @project = projects(:one)
  end

  test "a sandbox purchase posted to the production endpoint is refused and records no revenue" do
    txn = "sbx_#{SecureRandom.hex(4)}"

    assert_no_difference ["PurchaseEvent.count", "IapWebhookMessage.count"] do
      post_sandbox_subscribe("production", txn)
    end
    assert_response :ok
    assert_equal "unprocessed", JSON.parse(response.body)["result"]
  end

  test "the same sandbox purchase on the sandbox endpoint is processed" do
    txn = "sbx_#{SecureRandom.hex(4)}"

    post_sandbox_subscribe("test", txn)

    assert_response :ok
    assert_equal "ok", JSON.parse(response.body)["result"]
    assert PurchaseEvent.exists?(project: @project, transaction_id: txn, event_type: Grovs::Purchases::EVENT_BUY)
  end

  private

  def post_sandbox_subscribe(endpoint, txn)
    payloads = {
      "outer" => { "notificationType" => "SUBSCRIBED", "subtype" => "INITIAL_BUY",
                   "data" => { "bundleId" => "com.test.iosapp", "environment" => Grovs::Apple::ENV_SANDBOX,
                               "signedTransactionInfo" => "txn", "signedRenewalInfo" => "renewal" } },
      "txn" => { "transactionId" => txn, "originalTransactionId" => txn, "productId" => "com.test.monthly",
                 "bundleId" => "com.test.iosapp", "price" => 9990, "currency" => "USD",
                 "purchaseDate" => Time.current.to_i * 1000, "expiresDate" => 1.month.from_now.to_i * 1000,
                 "environment" => Grovs::Apple::ENV_SANDBOX },
      "renewal" => { "expiresDate" => 1.month.from_now.to_i * 1000 }
    }
    AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, ->(jws) { payloads.fetch(jws) }) do
      post "#{IAP_PREFIX}/apple/#{endpoint}/#{@project.hashid}",
           env: { "RAW_POST_DATA" => '{"signedPayload":"outer"}', "CONTENT_TYPE" => "application/json" }
    end
  end
end
