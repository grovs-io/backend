require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class PurchasesApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :devices, :purchase_events

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @project_two = projects(:two)
    @headers = doorkeeper_headers_for(@admin_user)

    # Clear fixture data and create controlled test data so counts
    # don't break when someone adds a new fixture to purchase_events.yml
    PurchaseEvent.where(project: @project).delete_all

    # 8 events matching the assertions in these tests
    PurchaseEvent.create!(event_type: "buy", device: devices(:ios_device), project: @project,
      identifier: "com.test.app", price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: "2026-03-01 10:00:00", transaction_id: "txn_buy_001",
      original_transaction_id: "orig_txn_001", product_id: "com.test.premium",
      webhook_validated: true, store: true, processed: true, purchase_type: "subscription",
      store_source: "apple", expires_date: "2027-03-01 10:00:00")
    PurchaseEvent.create!(event_type: "buy", device: devices(:ios_device), project: @project,
      identifier: "com.test.app", price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: "2026-03-02 10:00:00", transaction_id: "txn_buy_002",
      original_transaction_id: "orig_txn_001", product_id: "com.test.premium",
      webhook_validated: true, store: true, processed: true, purchase_type: "subscription")
    PurchaseEvent.create!(event_type: "cancel", device: devices(:ios_device), project: @project,
      identifier: "com.test.app", price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: "2026-03-03 10:00:00", transaction_id: "txn_cancel_001",
      original_transaction_id: "orig_txn_001", product_id: "com.test.premium",
      webhook_validated: true, store: true, processed: true, purchase_type: "subscription")
    PurchaseEvent.create!(event_type: "refund", device: devices(:ios_device), project: @project,
      identifier: "com.test.app", price_cents: 499, currency: "USD", usd_price_cents: 499,
      date: "2026-03-03 12:00:00", transaction_id: "txn_refund_001",
      original_transaction_id: "orig_txn_002", product_id: "com.test.onetime",
      webhook_validated: true, store: true, processed: true, purchase_type: "one_time")
    PurchaseEvent.create!(event_type: "buy", device: devices(:android_device), project: @project,
      identifier: "com.test.app", price_cents: 499, currency: "USD", usd_price_cents: 499,
      date: "2026-03-01 14:00:00", transaction_id: "txn_buy_ot_001",
      original_transaction_id: "orig_txn_002", product_id: "com.test.onetime",
      webhook_validated: true, store: true, processed: true, purchase_type: "one_time",
      store_source: "google")
    PurchaseEvent.create!(event_type: "buy", device: devices(:ios_device), project: @project,
      identifier: "com.test.app", price_cents: 1999, currency: "USD", usd_price_cents: 1999,
      date: "2026-03-04 10:00:00", transaction_id: "txn_buy_unprocessed",
      original_transaction_id: "orig_txn_003", product_id: "com.test.premium",
      webhook_validated: true, store: true, processed: false, purchase_type: "subscription")
    PurchaseEvent.create!(event_type: "buy", project: @project,
      identifier: "com.test.app", price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: "2026-03-01 16:00:00", transaction_id: "txn_buy_nodev",
      original_transaction_id: "orig_txn_004", product_id: "com.test.premium",
      webhook_validated: true, store: true, processed: true, purchase_type: "subscription")
    # nil_usd_buy: usd_price_cents must be nil (before_save auto-converts, so null it after)
    nil_usd = PurchaseEvent.create!(event_type: "buy", device: devices(:ios_device), project: @project,
      identifier: "com.test.app", price_cents: 500, currency: "EUR",
      date: "2026-03-04 12:00:00", transaction_id: "txn_nil_usd",
      original_transaction_id: "orig_txn_005", product_id: "com.test.premium",
      webhook_validated: true, store: true, processed: false, purchase_type: "subscription")
    nil_usd.update_column(:usd_price_cents, nil)
  end

  # --- Unauthenticated ---

  test "search purchases without auth returns 401 with no data" do
    post "#{API_PREFIX}/projects/#{@project.id}/purchases/search",
      params: { page: 1 },
      headers: api_headers
    assert_response :unauthorized
    assert_no_match(/"data"/, response.body, "401 must not leak purchase data")
  end

  # --- Search Purchases ---

  test "search purchases returns all fixture events with correct field values" do
    post "#{API_PREFIX}/projects/#{@project.id}/purchases/search",
      params: { page: 1, sort_by: "date", ascendent: "false" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    data = json["data"]
    assert_kind_of Array, data, "must return data array"

    # All fixture purchase_events belong to project :one
    # 8 total events in the fixture (7 store+validated, 1 unprocessed)
    assert_equal 8, json["total_entries"], "must return all 8 fixture purchase events"
    assert_kind_of Integer, json["page"], "page must be an integer"
    assert json.key?("per_page"), "must return per_page"
    assert json.key?("total_pages"), "must return total_pages"

    # Verify buy_event appears with correct field values
    buy = data.find { |p| p["transaction_id"] == "txn_buy_001" }
    assert_not_nil buy, "buy_event must appear in results"
    assert_equal "buy", buy["event_type"], "event_type must be 'buy'"
    assert_equal "subscription", buy["purchase_type"], "purchase_type must be 'subscription'"
    assert_equal "com.test.premium", buy["product_id"], "product_id must match fixture"
    assert_equal 999, buy["price_cents"], "price_cents must be 999"
    assert_equal 999, buy["usd_price_cents"], "usd_price_cents must be 999"
    assert_equal "USD", buy["currency"], "currency must be USD"
    assert buy["webhook_validated"], "webhook_validated must be true"
    assert_equal "ios", buy["platform"], "platform must come from ios_device"

    # Verify cancel_event
    cancel = data.find { |p| p["transaction_id"] == "txn_cancel_001" }
    assert_not_nil cancel, "cancel_event must appear in results"
    assert_equal "cancel", cancel["event_type"], "cancel event_type must be 'cancel'"

    # Verify refund_event with different price
    refund = data.find { |p| p["transaction_id"] == "txn_refund_001" }
    assert_not_nil refund, "refund_event must appear in results"
    assert_equal "refund", refund["event_type"], "refund event_type must be 'refund'"
    assert_equal "one_time", refund["purchase_type"], "refund purchase_type must be 'one_time'"
    assert_equal 499, refund["usd_price_cents"], "refund usd_price_cents must be 499"
  end

  # --- Revenue Metrics ---

  test "revenue metrics returns paginated data structure" do
    post "#{API_PREFIX}/projects/#{@project.id}/purchases/revenue",
      params: {
        start_date: "2026-03-01",
        end_date: "2026-03-04",
        page: 1
      },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["data"], "must return data array"
    assert json.key?("total_entries"), "must return total_entries"
    assert json.key?("page"), "must return page"
    # Revenue is aggregated from in_app_product_daily_statistics table
    # which has no fixtures — so data will be empty, but structure is correct
    assert_kind_of Integer, json["total_entries"], "total_entries must be integer"
  end

  # --- Default Pagination ---

  test "search without page or sort_by uses defaults" do
    post "#{API_PREFIX}/projects/#{@project.id}/purchases/search",
      params: {},
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["data"], "must return data array"
    assert_equal 1, json["page"], "page must default to 1"
    assert json.key?("per_page"), "must include per_page"
    assert json.key?("total_entries"), "must include total_entries"
  end

  # --- Empty Revenue Data ---

  test "revenue with future date range returns empty data" do
    post "#{API_PREFIX}/projects/#{@project.id}/purchases/revenue",
      params: { start_date: "2099-01-01", end_date: "2099-12-31", page: 1 },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["data"], "must return data array"
    assert_equal 0, json["data"].size, "future date range must have no data"
    assert_kind_of Integer, json["total_entries"], "total_entries must be integer"
  end

  # --- Page Beyond Range ---

  test "search with page beyond range returns empty data with correct total" do
    post "#{API_PREFIX}/projects/#{@project.id}/purchases/search",
      params: { page: 999, sort_by: "date" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["data"], "must return data array"
    assert_equal 0, json["data"].size, "page 999 must be empty"
    assert_equal 999, json["page"], "must reflect requested page"
    assert_equal 8, json["total_entries"], "total_entries must reflect all fixture events"
  end

  # --- Cross-Tenant ---

  test "access another instance project purchases returns 403 with no data leak" do
    post "#{API_PREFIX}/projects/#{@project_two.id}/purchases/search",
      params: { page: 1 },
      headers: @headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Forbidden", json["error"]
    assert_not json.key?("data"), "403 must not leak purchase data"
    assert_not json.key?("purchases"), "403 must not leak purchase data"
  end
end
