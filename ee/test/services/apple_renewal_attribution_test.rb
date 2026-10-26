require "test_helper"

class AppleRenewalAttributionTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :domains, :redirect_configs,
           :applications, :ios_configurations

  setup do
    @project = projects(:one)
    @first_link = make_link("first-#{SecureRandom.hex(3)}")
    @latest_link = make_link("latest-#{SecureRandom.hex(3)}")
  end

  test "a renewal with no subscription state is credited to the latest prior purchase's device and link" do
    original_id = "orig_renew_#{SecureRandom.hex(4)}"
    record_purchase(original_id, "#{original_id}_a", devices(:android_device), @first_link, 2.months.ago)
    record_purchase(original_id, "#{original_id}_b", devices(:ios_device), @latest_link, 1.month.ago)
    assert_nil SubscriptionState.find_by(project: @project, original_transaction_id: original_id)

    assert deliver_did_renew(original_id, "#{original_id}_c")

    renewal = PurchaseEvent.find_by!(project: @project, transaction_id: "#{original_id}_c")
    assert_equal devices(:ios_device).id, renewal.device_id
    assert_equal @latest_link.id, renewal.link_id
  end

  private

  def make_link(path)
    Link.create!(domain: domains(:one), path: path, redirect_config: redirect_configs(:one),
                 generated_from_platform: Grovs::Platforms::IOS)
  end

  def record_purchase(original_id, transaction_id, device, link, date)
    PurchaseEvent.create!(
      project: @project, device: device, link: link, event_type: Grovs::Purchases::EVENT_BUY,
      identifier: "com.test.iosapp", product_id: "com.test.monthly", price_cents: 999, currency: "USD",
      usd_price_cents: 999, date: date, transaction_id: transaction_id, original_transaction_id: original_id,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION, webhook_validated: true, store: true,
      store_source: Grovs::Webhooks::APPLE
    )
  end

  def deliver_did_renew(original_id, transaction_id)
    payloads = {
      "outer" => { "notificationType" => "DID_RENEW",
                   "data" => { "bundleId" => "com.test.iosapp", "environment" => Grovs::Apple::ENV_PRODUCTION,
                               "signedTransactionInfo" => "txn", "signedRenewalInfo" => "renewal" } },
      "txn" => { "transactionId" => transaction_id, "originalTransactionId" => original_id,
                 "productId" => "com.test.monthly", "bundleId" => "com.test.iosapp", "price" => 9990,
                 "currency" => "USD", "purchaseDate" => Time.current.to_i * 1000,
                 "expiresDate" => 1.month.from_now.to_i * 1000, "environment" => Grovs::Apple::ENV_PRODUCTION },
      "renewal" => { "expiresDate" => 1.month.from_now.to_i * 1000 }
    }
    AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, ->(jws) { payloads.fetch(jws) }) do
      AppleIapService.new.handle_notification({ "signedPayload" => "outer" }, @project)
    end
  end
end
