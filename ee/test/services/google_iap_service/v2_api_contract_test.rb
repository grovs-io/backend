require "test_helper"
require "google/apis/androidpublisher_v3"

# Tests that verify our code works with REAL gem classes, not OpenStruct.
# If a field name is wrong, these tests fail — OpenStruct tests would silently pass.
class GoogleIapService::V2ApiContractTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices

  GApi = Google::Apis::AndroidpublisherV3

  setup do
    @project = projects(:one)
    @instance = instances(:one)
    @service_instance = GoogleIapService.new
  end

  # ---------------------------------------------------------------------------
  # handle_bundle_or_unknown with real ProductPurchaseV2 + ProductLineItem
  # ---------------------------------------------------------------------------

  test "v2 bundle path works with real gem objects" do
    line_item_a = GApi::ProductLineItem.new(
      product_id: "com.test.sword",
      product_offer_details: GApi::ProductOfferDetails.new(quantity: 2)
    )
    line_item_b = GApi::ProductLineItem.new(
      product_id: "com.test.shield",
      product_offer_details: GApi::ProductOfferDetails.new(quantity: 1)
    )

    purchase_v2 = GApi::ProductPurchaseV2.new(
      product_line_item: [line_item_a, line_item_b],
      order_id: "GPA.real-gem-001",
      test_purchase_context: nil,
      purchase_completion_time: "2025-01-01T00:00:00Z"
    )

    batch_products = [
      GApi::InAppProduct.new(sku: "com.test.sword", default_price: GApi::Price.new(price_micros: "2990000", currency: "USD")),
      GApi::InAppProduct.new(sku: "com.test.shield", default_price: GApi::Price.new(price_micros: "4990000", currency: "EUR"))
    ]

    fake_service = Object.new
    fake_service.define_singleton_method(:getproductpurchasev2_purchase_productsv2) { |*_| purchase_v2 }
    fake_service.define_singleton_method(:batch_inappproduct_get) { |_pkg, **_kw| GApi::InappproductsBatchGetResponse.new(inappproduct: batch_products) }
    @service_instance.instance_variable_set(:@service, fake_service)

    webhook = create_webhook
    result = @service_instance.send(
      :handle_one_time_notification,
      { "oneTimeProductNotification" => { "purchaseToken" => "token_real_gem" } },
      @instance, webhook, "com.test.app"
    )
    assert result

    events = PurchaseEvent.where(original_transaction_id: "token_real_gem", event_type: Grovs::Purchases::EVENT_BUY)
    assert_equal 2, events.count

    sword = events.find_by(product_id: "com.test.sword")
    assert_equal 299, sword.price_cents
    assert_equal "USD", sword.currency
    assert_equal 2, sword.quantity

    shield = events.find_by(product_id: "com.test.shield")
    assert_equal 499, shield.price_cents
    assert_equal "EUR", shield.currency
    assert_equal 1, shield.quantity
  end

  # ---------------------------------------------------------------------------
  # v2 single product path with real gem objects
  # ---------------------------------------------------------------------------

  test "v2 single product path works with real gem objects" do
    line_item = GApi::ProductLineItem.new(
      product_id: "com.test.gems",
      product_offer_details: GApi::ProductOfferDetails.new(quantity: 5)
    )

    purchase_v2 = GApi::ProductPurchaseV2.new(
      product_line_item: [line_item],
      order_id: "GPA.real-single-001",
      test_purchase_context: nil,
      purchase_completion_time: "2025-06-15T12:00:00Z"
    )

    product_details = GApi::InAppProduct.new(
      default_price: GApi::Price.new(price_micros: "990000", currency: "GBP")
    )

    fake_service = Object.new
    fake_service.define_singleton_method(:getproductpurchasev2_purchase_productsv2) { |*_| purchase_v2 }
    fake_service.define_singleton_method(:get_inappproduct) { |*_| product_details }
    @service_instance.instance_variable_set(:@service, fake_service)

    webhook = create_webhook
    result = @service_instance.send(
      :handle_one_time_notification,
      { "oneTimeProductNotification" => { "purchaseToken" => "token_real_single" } },
      @instance, webhook, "com.test.app"
    )
    assert result

    event = PurchaseEvent.find_by(transaction_id: "token_real_single")
    assert event
    assert_equal 99, event.price_cents
    assert_equal "GBP", event.currency
    assert_equal 5, event.quantity
    assert_equal Time.parse("2025-06-15T12:00:00Z").to_i, event.date.to_i
  end

  # ---------------------------------------------------------------------------
  # test_purchase_context selects test project with real gem object
  # ---------------------------------------------------------------------------

  test "test_purchase_context present selects test project" do
    test_project = projects(:one_test)

    line_item = GApi::ProductLineItem.new(
      product_id: "com.test.item",
      product_offer_details: nil
    )

    purchase_v2 = GApi::ProductPurchaseV2.new(
      product_line_item: [line_item],
      order_id: "GPA.test-context-001",
      test_purchase_context: GApi::TestPurchaseContext.new(fop_type: "TEST_CARD"),
      purchase_completion_time: "2025-01-01T00:00:00Z"
    )

    fake_service = Object.new
    fake_service.define_singleton_method(:getproductpurchasev2_purchase_productsv2) { |*_| purchase_v2 }
    fake_service.define_singleton_method(:get_inappproduct) { |*_| nil }
    @service_instance.instance_variable_set(:@service, fake_service)

    webhook = create_webhook
    @service_instance.send(
      :handle_one_time_notification,
      { "oneTimeProductNotification" => { "purchaseToken" => "token_test_ctx" } },
      @instance, webhook, "com.test.app"
    )

    event = PurchaseEvent.find_by(transaction_id: "token_test_ctx")
    assert event
    assert_equal test_project.id, event.project_id
  end

  # ---------------------------------------------------------------------------
  # RentalSupport with real gem objects
  # ---------------------------------------------------------------------------

  test "rental detection works with real ProductLineItem" do
    rental_item = GApi::ProductLineItem.new(
      product_id: "com.test.movie",
      product_offer_details: GApi::ProductOfferDetails.new(
        rent_offer_details: GApi::RentOfferDetails.new
      )
    )

    non_rental_item = GApi::ProductLineItem.new(
      product_id: "com.test.book",
      product_offer_details: GApi::ProductOfferDetails.new(rent_offer_details: nil)
    )

    plain_item = GApi::ProductLineItem.new(
      product_id: "com.test.plain",
      product_offer_details: nil
    )

    assert GoogleIapService::RentalSupport.rental?(rental_item), "Should detect rental"
    assert_not GoogleIapService::RentalSupport.rental?(non_rental_item), "Should not be rental"
    assert_not GoogleIapService::RentalSupport.rental?(plain_item), "Should not be rental"
  end

  test "rental detection works with real ProductPurchaseV2" do
    rental_v2 = GApi::ProductPurchaseV2.new(
      product_line_item: [
        GApi::ProductLineItem.new(
          product_id: "com.test.movie",
          product_offer_details: GApi::ProductOfferDetails.new(
            rent_offer_details: GApi::RentOfferDetails.new
          )
        )
      ]
    )

    non_rental_v2 = GApi::ProductPurchaseV2.new(
      product_line_item: [
        GApi::ProductLineItem.new(
          product_id: "com.test.book",
          product_offer_details: GApi::ProductOfferDetails.new(rent_offer_details: nil)
        )
      ]
    )

    assert GoogleIapService::RentalSupport.rental?(rental_v2), "Should detect rental on v2 response"
    assert_not GoogleIapService::RentalSupport.rental?(non_rental_v2), "Should not be rental on v2 response"
  end

  # ---------------------------------------------------------------------------
  # quantity extraction with real gem objects
  # ---------------------------------------------------------------------------

  test "extract_v2_line_item_quantity works with real ProductLineItem" do
    item_with_qty = GApi::ProductLineItem.new(
      product_id: "com.test.item",
      product_offer_details: GApi::ProductOfferDetails.new(quantity: 7)
    )

    item_no_offer = GApi::ProductLineItem.new(
      product_id: "com.test.item",
      product_offer_details: nil
    )

    item_nil_qty = GApi::ProductLineItem.new(
      product_id: "com.test.item",
      product_offer_details: GApi::ProductOfferDetails.new(quantity: nil)
    )

    assert_equal 7, @service_instance.send(:extract_v2_line_item_quantity, item_with_qty)
    assert_equal 1, @service_instance.send(:extract_v2_line_item_quantity, item_no_offer)
    assert_equal 1, @service_instance.send(:extract_v2_line_item_quantity, item_nil_qty)
  end

  private

  def create_webhook
    IapWebhookMessage.create!(
      payload: "test",
      notification_type: "UNKNOWN",
      source: Grovs::Webhooks::GOOGLE,
      instance: @instance
    )
  end
end
