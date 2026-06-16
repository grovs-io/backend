require "test_helper"

class PurchaseAttributionServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events, :subscription_states

  include PurchaseAttributionService

  setup do
    @project = projects(:one)
  end

  test "find_attribution_from_previous_purchase returns from subscription_states first" do
    result = find_attribution_from_previous_purchase("orig_txn_001", @project)

    assert_equal devices(:ios_device).id, result[:device_id]
  end

  test "find_attribution_from_previous_purchase falls back to purchase_events" do
    # Remove the subscription_state
    SubscriptionState.where(original_transaction_id: "orig_txn_001").delete_all

    result = find_attribution_from_previous_purchase("orig_txn_001", @project)

    assert_equal devices(:ios_device).id, result[:device_id]
  end

  test "find_attribution_from_previous_purchase returns nils for unknown transaction" do
    result = find_attribution_from_previous_purchase("nonexistent_txn", @project)

    assert_nil result[:device_id]
    assert_nil result[:link_id]
  end

  test "find_attribution_from_previous_purchase returns both device_id and link_id" do
    # Create an event with both device and link
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:ios_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      usd_price_cents: 999,
      date: Time.current,
      transaction_id: "txn_both_attrs",
      original_transaction_id: "orig_both_attrs",
      product_id: "com.test.premium",
      webhook_validated: true,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      link_id: nil
    )

    result = find_attribution_from_previous_purchase("orig_both_attrs", @project)
    assert_equal devices(:ios_device).id, result[:device_id]
  end

  # --- New: cross-project isolation, link_id from subscription_state, fallback ordering ---

  test "find_attribution returns link_id from subscription_state" do
    link = Link.create!(
      domain: Domain.find_by(project: @project),
      path: "attr-link-#{SecureRandom.hex(4)}",
      redirect_config: RedirectConfig.find_by(project: @project),
      generated_from_platform: Grovs::Platforms::WEB
    )
    SubscriptionState.create!(
      project: @project,
      original_transaction_id: "orig_link_test",
      device_id: devices(:ios_device).id,
      link_id: link.id,
      product_id: "com.test.link",
      latest_transaction_id: "txn_link_001",
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    result = find_attribution_from_previous_purchase("orig_link_test", @project)
    assert_equal link.id, result[:link_id]
    assert_equal devices(:ios_device).id, result[:device_id]
  end

  test "find_attribution scopes by project_id (cross-project isolation)" do
    project_two = projects(:two)

    # Create a subscription_state for project_two with same transaction_id
    SubscriptionState.create!(
      project: project_two,
      original_transaction_id: "orig_txn_001",
      device_id: devices(:android_device).id,
      product_id: "com.test.other",
      latest_transaction_id: "txn_other_001",
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    # Querying project_two should return android device, not ios device
    result = find_attribution_from_previous_purchase("orig_txn_001", project_two)
    assert_equal devices(:android_device).id, result[:device_id]
  end

  test "find_attribution prefers most recent purchase_event on fallback" do
    SubscriptionState.where(original_transaction_id: "orig_txn_001").delete_all

    # Create two purchase_events with different dates
    PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:android_device),
      project: @project,
      price_cents: 100, currency: "USD", usd_price_cents: 100,
      date: 2.days.ago,
      transaction_id: "txn_old_fallback",
      original_transaction_id: "orig_txn_001",
      product_id: "com.test.premium"
    )
    PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:ios_device),
      project: @project,
      price_cents: 200, currency: "USD", usd_price_cents: 200,
      date: 1.day.ago,
      transaction_id: "txn_new_fallback",
      original_transaction_id: "orig_txn_001",
      product_id: "com.test.premium"
    )

    result = find_attribution_from_previous_purchase("orig_txn_001", @project)
    # Should pick the most recent (ios_device, 1 day ago)
    assert_equal devices(:ios_device).id, result[:device_id]
  end
end

class CachedGoogleJsonKeyTest < ActiveSupport::TestCase
  # android_server_api_keys must be in the fixture set: other classes in the same
  # worker load it, and the has_one would return that fixture row (no attached
  # file) instead of the key created here.
  fixtures :instances, :projects, :applications, :android_configurations,
           :android_server_api_keys

  include PurchaseAttributionService

  setup do
    @instance = instances(:one)
    @config = android_configurations(:one)
    @cache = ActiveSupport::Cache::MemoryStore.new
  end

  def attach_key(content)
    AndroidServerApiKey.where(android_configuration: @config).destroy_all
    AndroidServerApiKey.create!(
      android_configuration: @config,
      file: { io: StringIO.new(content), filename: "sa.json", content_type: "application/json" }
    )
  end

  test "returns nil when instance has no key file" do
    assert_nil cached_google_json_key(@instance)
    assert_nil cached_google_json_key(nil)
  end

  test "downloads on cache miss, then serves from cache even if the blob is gone" do
    key = attach_key('{"type":"service_account"}')

    Rails.stub(:cache, @cache) do
      assert_equal '{"type":"service_account"}', cached_google_json_key(@instance)

      blob = key.file.blob
      blob.service.delete(blob.key)
      assert_equal '{"type":"service_account"}', cached_google_json_key(@instance),
        "second call must be served from cache, not re-downloaded"
    end
  end

  test "cache key is tied to the blob checksum so a rotated key re-downloads" do
    key = attach_key('{"v":1}')

    Rails.stub(:cache, @cache) do
      assert_equal '{"v":1}', cached_google_json_key(@instance)

      key.file.attach(io: StringIO.new('{"v":2}'), filename: "sa2.json",
                      content_type: "application/json")
      @instance.reload
      assert_equal '{"v":2}', cached_google_json_key(@instance),
        "rotated key file must not be served from the old cache entry"
    end
  end
end
