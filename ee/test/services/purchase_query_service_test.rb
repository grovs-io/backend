require "test_helper"

class PurchaseQueryServiceTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :devices, :purchase_events

  setup do
    @project = projects(:one)

    # Clear fixture data and create controlled test data so counts
    # don't break when someone adds a new fixture to purchase_events.yml
    PurchaseEvent.where(project: @project).delete_all

    # 8 events: 6 buy, 1 cancel, 1 refund — all store+validated (visible to search)
    # Dates: 3 on 03-01, 1 on 03-02, 2 on 03-03, 2 on 03-04
    # 7 have usd_price_cents set, 1 (nil_usd) has nil
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

    @service = PurchaseQueryService.new(project: @project)
  end

  # --- base scope: store/webhook_validated filtering ---

  test "search includes store purchases that are webhook_validated" do
    result = @service.search
    store_events = result.select(&:store)
    store_events.each do |pe|
      assert pe.webhook_validated,
        "Store purchase #{pe.transaction_id} should be webhook_validated"
    end
  end

  test "search includes non-store purchases" do
    # Create a non-store purchase event (e.g., SDK-reported)
    non_store = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: @project,
      store: false,
      webhook_validated: false,
      date: Time.current,
      price_cents: 100,
      currency: "USD",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    result = @service.search
    assert result.any? { |pe| pe.id == non_store.id },
      "Non-store purchase should be included regardless of webhook_validated"
  end

  test "search excludes store purchases that are not webhook_validated" do
    unvalidated = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: @project,
      store: true,
      webhook_validated: false,
      date: Time.current,
      price_cents: 500,
      currency: "USD",
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    result = @service.search
    assert_not result.any? { |pe| pe.id == unvalidated.id },
      "Store purchase with webhook_validated=false must be excluded"
  end

  # --- project scoping ---

  test "search scopes results to the given project" do
    result = @service.search
    # 8 fixture purchase events for project :one (all store=true, webhook_validated=true)
    assert_equal 8, result.size
    result.each { |pe| assert_equal @project.id, pe.project_id }
  end

  test "search returns empty for project with no purchases" do
    service = PurchaseQueryService.new(project: projects(:two))
    result = service.search
    assert_empty result
  end

  # --- date range filtering ---

  test "search filters by date range returns matching events" do
    result = @service.search(start_date: "2026-03-01", end_date: "2026-03-01")
    # buy_event (10:00), buy_one_time (14:00), no_device_buy (16:00) = 3 events on 2026-03-01
    assert_equal 3, result.size
    result.each do |pe|
      assert pe.date >= Date.new(2026, 3, 1).beginning_of_day
      assert pe.date <= Date.new(2026, 3, 1).end_of_day
    end
  end

  test "search with narrow date range returns only that day" do
    result = @service.search(start_date: "2026-03-03", end_date: "2026-03-03")
    # cancel_event (10:00) + refund_event (12:00) = 2 events on 2026-03-03
    assert_equal 2, result.size
    result.each do |pe|
      assert_equal Date.new(2026, 3, 3), pe.date.to_date,
        "Event #{pe.transaction_id} date #{pe.date} should be on 2026-03-03"
    end
  end

  test "search with distant past date range returns empty" do
    result = @service.search(start_date: "2000-01-01", end_date: "2000-01-02")
    assert_empty result
  end

  # --- term filtering ---

  test "search filters by event_type term finding buy events" do
    result = @service.search(term: "buy")
    # buy_event, buy_event_repeat, buy_one_time, unprocessed_buy, no_device_buy, nil_usd_buy = 6
    assert_equal 6, result.size
    result.each { |pe| assert_match(/buy/i, pe.event_type) }
  end

  test "search filters by event_type term finding cancel events" do
    result = @service.search(term: "cancel")
    # cancel_event = 1 cancel event in fixtures
    assert_equal 1, result.size
    result.each { |pe| assert_match(/cancel/i, pe.event_type) }
  end

  test "search term excludes non-matching event types" do
    result = @service.search(term: "buy")
    assert_not result.any? { |pe| pe.event_type == "cancel" },
      "Term 'buy' should not return cancel events"
    assert_not result.any? { |pe| pe.event_type == "refund" },
      "Term 'buy' should not return refund events"
  end

  test "search term with no matches returns empty" do
    result = @service.search(term: "nonexistent_event_type")
    assert_empty result
  end

  test "search term sanitizes sql wildcards" do
    # The % character should be escaped so it's treated literally, not as SQL wildcard
    result = @service.search(term: "100%")
    assert_empty result, "Literal '100%' should not match any event_type"
  end

  # --- sorting ---

  test "search sorts by usd_price_cents ascending" do
    result = @service.search(sort_by: "usd_price_cents", asc: true)
    prices = result.map(&:usd_price_cents).compact
    # 7 of 8 fixture events have usd_price_cents set (nil_usd_buy has nil)
    assert_equal 7, prices.size
    assert_equal prices.sort, prices
  end

  test "search sorts by usd_price_cents descending" do
    result = @service.search(sort_by: "usd_price_cents", asc: false)
    prices = result.map(&:usd_price_cents).compact
    # 7 of 8 fixture events have usd_price_cents set (nil_usd_buy has nil)
    assert_equal 7, prices.size
    assert_equal prices.sort.reverse, prices
  end

  test "search defaults to date desc for invalid sort column" do
    result = @service.search(sort_by: "DROP TABLE purchase_events")
    dates = result.map(&:date)
    dates.each_cons(2) do |a, b|
      assert a >= b, "Expected date desc order, got #{a} before #{b}"
    end
  end

  test "search sorts by event_type ascending" do
    result = @service.search(sort_by: "event_type", asc: true)
    types = result.map(&:event_type)
    assert_equal types.sort, types
  end

  # --- pagination ---

  test "search paginates results" do
    result = @service.search(page: 1)
    assert result.current_page == 1
  end

  test "search clamps negative page to 1" do
    result = @service.search(page: -5)
    assert_equal 1, result.current_page
  end

  test "search clamps nil page to 1" do
    result = @service.search(page: nil)
    assert_equal 1, result.current_page
  end

  # --- sort by date column ---

  test "search sorts by date ascending" do
    result = @service.search(sort_by: "date", asc: true)
    dates = result.map(&:date)
    dates.each_cons(2) do |a, b|
      assert a <= b, "Expected date asc order, got #{a} before #{b}"
    end
  end

  # --- sort by product_id column ---

  test "search sorts by product_id ascending" do
    result = @service.search(sort_by: "product_id", asc: true)
    product_ids = result.map(&:product_id).compact
    assert_equal product_ids.sort, product_ids
  end

  # --- underscore SQL wildcard sanitization ---

  test "search term escapes underscore so it is literal not SQL wildcard" do
    # "refund_reversed" is a valid event_type containing a literal underscore.
    PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_REFUND_REVERSED,
      project: @project,
      store: true,
      webhook_validated: true,
      date: Time.current,
      price_cents: 100,
      currency: "USD",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    # Search for "d_r" which literally occurs in "refund_reversed" (refun-d_r-eversed).
    # With proper escaping, _ is treated as literal so this matches "refund_reversed".
    # Without escaping, _ would match any char, potentially causing false positives.
    result = @service.search(term: "d_r")
    types = result.map(&:event_type)
    assert_includes types, "refund_reversed",
      "Escaped underscore search for 'd_r' should match 'refund_reversed' literally"

    # "d%r" should not match any event_type because % is also escaped to literal.
    result_pct = @service.search(term: "d%r")
    assert_empty result_pct, "Escaped percent in 'd%r' should not match any event_type"
  end

  # --- combined date + term filter ---

  test "search applies both date range and term filter simultaneously" do
    result = @service.search(
      start_date: "2026-03-01", end_date: "2026-03-01",
      term: "buy"
    )
    # On 2026-03-01 there are 3 events: buy_event, buy_one_time, no_device_buy — all "buy" type
    assert_equal 3, result.size
    result.each do |pe|
      assert_match(/buy/i, pe.event_type)
      assert pe.date >= Date.new(2026, 3, 1).beginning_of_day
      assert pe.date <= Date.new(2026, 3, 1).end_of_day
    end
  end
end
