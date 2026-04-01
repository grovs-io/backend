require "test_helper"

class GoogleIapService::BundleHandlerTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices

  setup do
    @project = projects(:one)
    @service_instance = GoogleIapService.new
  end

  # ---------------------------------------------------------------------------
  # 2-product bundle creates 2 PurchaseEvents
  # ---------------------------------------------------------------------------

  test "creates one event per line item" do
    setup_fake_service(
      "com.test.sword" => build_product_details(2_990_000, "USD"),
      "com.test.shield" => build_product_details(4_990_000, "USD")
    )

    line_items = build_line_items("com.test.sword", "com.test.shield")

    events = @service_instance.send(
      :handle_bundle_purchase,
      line_items: line_items,
      purchase_token: "token_bundle_001",
      order_id: "GPA.bundle-001",
      project: @project,
      package_name: "com.test.app"
    )

    assert_equal 2, events.size
    assert_equal %w[com.test.shield com.test.sword], events.map(&:product_id).sort
  end

  # ---------------------------------------------------------------------------
  # Shared order_id
  # ---------------------------------------------------------------------------

  test "all events share the same order_id" do
    setup_fake_service(
      "com.test.a" => build_product_details(1_000_000, "USD"),
      "com.test.b" => build_product_details(2_000_000, "USD")
    )

    line_items = build_line_items("com.test.a", "com.test.b")

    events = @service_instance.send(
      :handle_bundle_purchase,
      line_items: line_items,
      purchase_token: "token_shared_order",
      order_id: "GPA.shared-order",
      project: @project,
      package_name: "com.test.app"
    )

    assert events.all? { |e| e.order_id == "GPA.shared-order" }
  end

  # ---------------------------------------------------------------------------
  # Distinct transaction_ids
  # ---------------------------------------------------------------------------

  test "each event has distinct transaction_id based on token:product_id" do
    setup_fake_service(
      "com.test.x" => build_product_details(0, "USD"),
      "com.test.y" => build_product_details(0, "USD")
    )

    line_items = build_line_items("com.test.x", "com.test.y")

    events = @service_instance.send(
      :handle_bundle_purchase,
      line_items: line_items,
      purchase_token: "token_distinct",
      order_id: "GPA.distinct",
      project: @project,
      package_name: "com.test.app"
    )

    txn_ids = events.map(&:transaction_id).sort
    assert_equal ["token_distinct:com.test.x", "token_distinct:com.test.y"], txn_ids
  end

  # ---------------------------------------------------------------------------
  # Shared original_transaction_id
  # ---------------------------------------------------------------------------

  test "all events share original_transaction_id equal to purchase_token" do
    setup_fake_service(
      "com.test.p" => build_product_details(0, "USD"),
      "com.test.q" => build_product_details(0, "USD")
    )

    line_items = build_line_items("com.test.p", "com.test.q")

    events = @service_instance.send(
      :handle_bundle_purchase,
      line_items: line_items,
      purchase_token: "token_orig",
      order_id: "GPA.orig",
      project: @project,
      package_name: "com.test.app"
    )

    assert events.all? { |e| e.original_transaction_id == "token_orig" }
  end

  # ---------------------------------------------------------------------------
  # Per-product pricing from catalog
  # ---------------------------------------------------------------------------

  test "each event has per-product price from catalog" do
    setup_fake_service(
      "com.test.cheap" => build_product_details(990_000, "EUR"),
      "com.test.expensive" => build_product_details(19_990_000, "EUR")
    )

    line_items = build_line_items("com.test.cheap", "com.test.expensive")

    events = @service_instance.send(
      :handle_bundle_purchase,
      line_items: line_items,
      purchase_token: "token_pricing",
      order_id: "GPA.pricing",
      project: @project,
      package_name: "com.test.app"
    )

    cheap = events.find { |e| e.product_id == "com.test.cheap" }
    expensive = events.find { |e| e.product_id == "com.test.expensive" }

    assert_equal 99, cheap.price_cents
    assert_equal 1999, expensive.price_cents
    assert_equal "EUR", cheap.currency
    assert_equal "EUR", expensive.currency
  end

  # ---------------------------------------------------------------------------
  # Price defaults to 0 when catalog lookup fails
  # ---------------------------------------------------------------------------

  test "price defaults to 0 USD when product details unavailable" do
    setup_fake_service({})  # No products in catalog

    line_items = build_line_items("com.test.unknown")

    events = @service_instance.send(
      :handle_bundle_purchase,
      line_items: line_items,
      purchase_token: "token_no_price",
      order_id: "GPA.no-price",
      project: @project,
      package_name: "com.test.app"
    )

    assert_equal 1, events.size
    assert_equal 0, events.first.price_cents
    assert_equal "USD", events.first.currency
  end

  # ---------------------------------------------------------------------------
  # Batch product lookup — 1 API call instead of N
  # ---------------------------------------------------------------------------

  test "fetches product details in a single batch call with correct SKUs" do
    batch_call_count = 0
    individual_call_count = 0
    received_skus = nil

    all_products = {
      "com.test.a" => OpenStruct.new(sku: "com.test.a", default_price: build_product_details(1_000_000, "USD").default_price),
      "com.test.b" => OpenStruct.new(sku: "com.test.b", default_price: build_product_details(2_000_000, "USD").default_price),
      "com.test.c" => OpenStruct.new(sku: "com.test.c", default_price: build_product_details(3_000_000, "USD").default_price)
    }

    fake_service = Object.new
    fake_service.define_singleton_method(:batch_inappproduct_get) do |_pkg, **kwargs|
      batch_call_count += 1
      received_skus = kwargs[:sku]
      # Only return products that were actually requested
      requested = (kwargs[:sku] || []).filter_map { |s| all_products[s] }
      OpenStruct.new(inappproduct: requested)
    end
    fake_service.define_singleton_method(:get_inappproduct) do |_pkg, _pid|
      individual_call_count += 1
      nil
    end
    @service_instance.instance_variable_set(:@service, fake_service)

    line_items = build_line_items("com.test.a", "com.test.b", "com.test.c")

    events = @service_instance.send(
      :handle_bundle_purchase,
      line_items: line_items, purchase_token: "token_batch",
      order_id: "GPA.batch", project: @project, package_name: "com.test.app"
    )

    assert_equal 1, batch_call_count, "Should make exactly 1 batch API call"
    assert_equal 0, individual_call_count, "Should not fall back to individual calls"
    assert_equal %w[com.test.a com.test.b com.test.c], received_skus.sort,
      "Should pass all product IDs as SKUs to batch API"

    assert_equal 3, events.size
    prices = events.sort_by(&:product_id).map(&:price_cents)
    assert_equal [100, 200, 300], prices,
      "Prices must come from batch response, not default to 0"
  end

  test "falls back to individual calls when batch API fails" do
    individual_calls = []

    products = {
      "com.test.f1" => build_product_details(1_000_000, "USD"),
      "com.test.f2" => build_product_details(2_000_000, "USD")
    }

    fake_service = Object.new
    fake_service.define_singleton_method(:batch_inappproduct_get) do |_pkg, **_kw|
      raise Google::Apis::ServerError, "batch unavailable"
    end
    fake_service.define_singleton_method(:get_inappproduct) do |_pkg, pid|
      individual_calls << pid
      products[pid]
    end
    @service_instance.instance_variable_set(:@service, fake_service)

    line_items = build_line_items("com.test.f1", "com.test.f2")

    events = @service_instance.send(
      :handle_bundle_purchase,
      line_items: line_items, purchase_token: "token_fallback",
      order_id: "GPA.fallback", project: @project, package_name: "com.test.app"
    )

    assert_equal 2, events.size, "Should still create events via fallback"
    assert_equal %w[com.test.f1 com.test.f2], individual_calls.sort, "Should call get_inappproduct for each product"
    assert_equal 100, events.find { |e| e.product_id == "com.test.f1" }.price_cents
    assert_equal 200, events.find { |e| e.product_id == "com.test.f2" }.price_cents
  end

  # ---------------------------------------------------------------------------
  # Idempotent — duplicate call
  # ---------------------------------------------------------------------------

  test "duplicate call does not create second set of events" do
    setup_fake_service("com.test.dup" => build_product_details(1_000_000, "USD"))

    line_items = build_line_items("com.test.dup")

    params = {
      line_items: line_items,
      purchase_token: "token_dup_bundle",
      order_id: "GPA.dup-bundle",
      project: @project,
      package_name: "com.test.app"
    }

    @service_instance.send(:handle_bundle_purchase, **params)
    @service_instance.send(:handle_bundle_purchase, **params)

    count = PurchaseEvent.where(
      transaction_id: "token_dup_bundle:com.test.dup",
      event_type: Grovs::Purchases::EVENT_BUY,
      project_id: @project.id
    ).count
    assert_equal 1, count, "Should not create duplicate events"
  end

  private

  def build_line_items(*product_ids)
    product_ids.map do |pid|
      OpenStruct.new(product_id: pid, product_offer_details: nil)
    end
  end

  def build_product_details(price_micros, currency)
    OpenStruct.new(
      default_price: OpenStruct.new(price_micros: price_micros, currency: currency)
    )
  end

  # Set up a fake Google API service with batch_inappproduct_get (primary)
  # and get_inappproduct (fallback for single-product path).
  def setup_fake_service(product_catalog)
    # Inject sku from hash key so index_by(&:sku) works in batch response
    products = product_catalog.map { |pid, details| OpenStruct.new(sku: pid, default_price: details.default_price) }

    fake_service = Object.new
    fake_service.define_singleton_method(:batch_inappproduct_get) do |_package, **_kwargs|
      OpenStruct.new(inappproduct: products)
    end
    fake_service.define_singleton_method(:get_inappproduct) do |_package, product_id|
      product_catalog[product_id]
    end
    @service_instance.instance_variable_set(:@service, fake_service)
  end
end
