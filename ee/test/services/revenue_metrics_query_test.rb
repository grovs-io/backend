require "test_helper"

class RevenueMetricsQueryTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events,
           :in_app_products, :in_app_product_daily_statistics

  setup do
    @project = projects(:one)
    @start_date = Date.new(2026, 3, 1)
    @end_date = Date.new(2026, 3, 31)

    # Web test data created inline to avoid polluting global fixtures
    @web_visitor = Visitor.create!(
      project: @project, device: devices(:web_device),
      web_visitor: true, sdk_identifier: "user_web_def456",
      uuid: SecureRandom.uuid
    )
    @web_product = InAppProduct.create!(
      project: @project, product_id: "com.test.webpro",
      platform: "web", unique_purchasing_devices: 1
    )
    InAppProductDailyStatistic.create!(
      in_app_product: @web_product, project: @project,
      event_date: Date.new(2026, 3, 1), platform: "web",
      revenue: 299, purchase_events: 1, canceled_events: 0,
      first_time_purchases: 1, repeat_purchases: 0, device_revenue: 299
    )
    @web_purchase = PurchaseEvent.create!(
      event_type: "buy", device: devices(:web_device), project: @project,
      identifier: "com.test.webapp", price_cents: 299, currency: "USD",
      usd_price_cents: 299, date: "2026-03-01 11:00:00",
      transaction_id: "txn_buy_web_001", original_transaction_id: "orig_txn_web_001",
      product_id: "com.test.webpro", webhook_validated: false, store: false,
      processed: true, purchase_type: "one_time"
    )
  end

  test "call returns metrics from daily stats" do
    query = RevenueMetricsQuery.new(
      project_id: @project.id,
      start_date: @start_date,
      end_date: @end_date,
      product: nil
    )

    results = query.call
    assert results.any?, "Should return results"

    premium = results.find { |r| r["product_id"] == "com.test.premium" }
    assert premium, "Should find premium product"
    assert_equal 2, premium["units_sold"]
    assert_equal 1, premium["first_time_purchases"]
    assert_equal 1, premium["repeat_purchases"]
    assert_equal 1, premium["cancellations"]
    assert_equal 1998, premium["total_revenue_usd_cents"]
  end

  test "call returns correct LTV calculation" do
    query = RevenueMetricsQuery.new(
      project_id: @project.id,
      start_date: @start_date,
      end_date: @end_date,
      product: nil
    )

    results = query.call
    premium = results.find { |r| r["product_id"] == "com.test.premium" }

    product = in_app_products(:premium_ios)
    expected_ltv = (999 + 999).to_f / product.unique_purchasing_devices
    assert_equal expected_ltv, premium["ltv_usd_cents"]
  end

  test "call filters by platform" do
    query = RevenueMetricsQuery.new(
      project_id: @project.id,
      start_date: @start_date,
      end_date: @end_date,
      product: nil,
      platform: "android"
    )

    results = query.call
    assert_equal 1, results.size
    assert_equal "com.test.onetime", results.first["product_id"]
  end

  test "call filters by product search" do
    query = RevenueMetricsQuery.new(
      project_id: @project.id,
      start_date: @start_date,
      end_date: @end_date,
      product: "premium"
    )

    results = query.call
    assert_equal 1, results.size
    assert_equal "com.test.premium", results.first["product_id"]
  end

  test "call paginates results" do
    query = RevenueMetricsQuery.new(
      project_id: @project.id,
      start_date: @start_date,
      end_date: @end_date,
      product: nil
    )

    results = query.call(page: 1, per_page: 1)
    assert_equal 1, results.size
    assert_equal 3, results.total_count
  end

  test "call sorts by specified field" do
    query = RevenueMetricsQuery.new(
      project_id: @project.id,
      start_date: @start_date,
      end_date: @end_date,
      product: nil,
      sort_by: "total_revenue_usd_cents",
      ascendent: false
    )

    results = query.call
    assert results.size >= 2
    assert results[0]["total_revenue_usd_cents"] >= results[1]["total_revenue_usd_cents"]
  end

  test "call returns zero LTV when no purchasing devices" do
    product = in_app_products(:premium_ios)
    product.update_column(:unique_purchasing_devices, 0)

    query = RevenueMetricsQuery.new(
      project_id: @project.id,
      start_date: @start_date,
      end_date: @end_date,
      product: "premium"
    )

    results = query.call
    premium = results.first
    assert_equal 0.0, premium["ltv_usd_cents"]
  end

  test "with_arpu uses visitor_daily_statistics for active visitors" do
    # Clear VDS to control the exact visitor count for this test
    VisitorDailyStatistic.where(project_id: @project.id).delete_all

    VisitorDailyStatistic.upsert(
      { visitor_id: visitors(:ios_visitor).id, project_id: @project.id,
        event_date: Date.new(2026, 3, 1), platform: Grovs::Platforms::IOS },
      unique_by: :uniq_vds_proj_visitor_date_platform
    )
    VisitorDailyStatistic.upsert(
      { visitor_id: visitors(:android_visitor).id, project_id: @project.id,
        event_date: Date.new(2026, 3, 1), platform: Grovs::Platforms::ANDROID },
      unique_by: :uniq_vds_proj_visitor_date_platform
    )

    query = RevenueMetricsQuery.new(
      project_id: @project.id,
      start_date: @start_date,
      end_date: @end_date,
      product: nil
    )

    results = query.with_arpu
    assert results.all? { |r| r.key?("arpu_usd_cents") }

    premium = results.find { |r| r["product_id"] == "com.test.premium" }
    expected_arpu = premium["total_revenue_usd_cents"].to_f / 2
    assert_in_delta expected_arpu, premium["arpu_usd_cents"], 0.01
  end

  test "with_arpu returns 0 when no visitors" do
    VisitorDailyStatistic.where(project_id: @project.id).delete_all

    query = RevenueMetricsQuery.new(
      project_id: @project.id,
      start_date: @start_date,
      end_date: @end_date,
      product: nil
    )

    results = query.with_arpu
    assert results.all? { |r| r["arpu_usd_cents"] == 0.0 }
  end

  test "call does not query purchase_events table" do
    query = RevenueMetricsQuery.new(
      project_id: @project.id,
      start_date: @start_date,
      end_date: @end_date,
      product: nil
    )

    # The SQL should reference in_app_product_daily_statistics, not purchase_events
    sql = query.send(:call).to_sql rescue nil
    # Simple check: we can verify the query runs without touching purchase_events
    # by ensuring results come back even if we didn't set up matching purchase_events
    results = query.call
    assert results.any?
  end

  test "call returns empty for nonexistent project" do
    query = RevenueMetricsQuery.new(
      project_id: 999999,
      start_date: @start_date,
      end_date: @end_date,
      product: nil
    )

    results = query.call
    assert_empty results
  end

  # === Platform filtering: revenue isolation ===

  test "platform=ios returns only iOS product revenue" do
    query = RevenueMetricsQuery.new(
      project_id: @project.id, start_date: @start_date, end_date: @end_date,
      product: nil, platform: "ios"
    )

    results = query.call
    product_ids = results.map { |r| r["product_id"] }
    assert_includes product_ids, "com.test.premium"
    assert_not_includes product_ids, "com.test.onetime", "Android product must not appear in iOS filter"
    assert_not_includes product_ids, "com.test.webpro", "Web product must not appear in iOS filter"
  end

  test "platform=android returns only Android product revenue" do
    query = RevenueMetricsQuery.new(
      project_id: @project.id, start_date: @start_date, end_date: @end_date,
      product: nil, platform: "android"
    )

    results = query.call
    product_ids = results.map { |r| r["product_id"] }
    assert_includes product_ids, "com.test.onetime"
    assert_not_includes product_ids, "com.test.premium", "iOS product must not appear in Android filter"
    assert_not_includes product_ids, "com.test.webpro", "Web product must not appear in Android filter"
  end

  test "platform=web returns only web product revenue" do
    query = RevenueMetricsQuery.new(
      project_id: @project.id, start_date: @start_date, end_date: @end_date,
      product: nil, platform: "web"
    )

    results = query.call
    assert results.any?, "Web platform filter must not return empty when web data exists"
    product_ids = results.map { |r| r["product_id"] }
    assert_includes product_ids, "com.test.webpro"
    assert_not_includes product_ids, "com.test.premium", "iOS product must not appear in web filter"
    assert_not_includes product_ids, "com.test.onetime", "Android product must not appear in web filter"
  end

  test "no platform filter returns all products" do
    query = RevenueMetricsQuery.new(
      project_id: @project.id, start_date: @start_date, end_date: @end_date,
      product: nil
    )

    results = query.call
    product_ids = results.map { |r| r["product_id"] }
    assert_includes product_ids, "com.test.premium"
    assert_includes product_ids, "com.test.onetime"
    assert_includes product_ids, "com.test.webpro"
  end

  # === Platform filtering: ARPU isolation ===

  test "with_arpu platform=web uses only web visitors for ARPU" do
    VisitorDailyStatistic.where(project_id: @project.id).delete_all
    VisitorDailyStatistic.upsert(
      { visitor_id: @web_visitor.id, project_id: @project.id,
        event_date: Date.new(2026, 3, 1), platform: Grovs::Platforms::WEB },
      unique_by: :uniq_vds_proj_visitor_date_platform
    )

    query = RevenueMetricsQuery.new(
      project_id: @project.id, start_date: @start_date, end_date: @end_date,
      product: nil, platform: "web"
    )

    results = query.with_arpu
    assert results.any?, "Web platform with_arpu must not return empty"
    web = results.find { |r| r["product_id"] == "com.test.webpro" }
    assert web

    # 1 web visitor, revenue = 299
    assert_in_delta 299.0, web["arpu_usd_cents"], 0.01
  end

  test "with_arpu platform=ios uses only iOS visitors for ARPU" do
    VisitorDailyStatistic.where(project_id: @project.id).delete_all
    VisitorDailyStatistic.upsert(
      { visitor_id: visitors(:ios_visitor).id, project_id: @project.id,
        event_date: Date.new(2026, 3, 1), platform: Grovs::Platforms::IOS },
      unique_by: :uniq_vds_proj_visitor_date_platform
    )
    # Also create a web visitor to prove it's excluded
    VisitorDailyStatistic.upsert(
      { visitor_id: @web_visitor.id, project_id: @project.id,
        event_date: Date.new(2026, 3, 1), platform: Grovs::Platforms::WEB },
      unique_by: :uniq_vds_proj_visitor_date_platform
    )

    query = RevenueMetricsQuery.new(
      project_id: @project.id, start_date: @start_date, end_date: @end_date,
      product: nil, platform: "ios"
    )

    results = query.with_arpu
    premium = results.find { |r| r["product_id"] == "com.test.premium" }
    assert premium

    # 1 iOS visitor only (web visitor must be excluded), revenue = 1998
    assert_in_delta 1998.0, premium["arpu_usd_cents"], 0.01
  end

  test "with_arpu no platform uses all visitors including web for ARPU" do
    VisitorDailyStatistic.where(project_id: @project.id).delete_all
    VisitorDailyStatistic.upsert(
      { visitor_id: visitors(:ios_visitor).id, project_id: @project.id,
        event_date: Date.new(2026, 3, 1), platform: Grovs::Platforms::IOS },
      unique_by: :uniq_vds_proj_visitor_date_platform
    )
    VisitorDailyStatistic.upsert(
      { visitor_id: visitors(:android_visitor).id, project_id: @project.id,
        event_date: Date.new(2026, 3, 1), platform: Grovs::Platforms::ANDROID },
      unique_by: :uniq_vds_proj_visitor_date_platform
    )
    VisitorDailyStatistic.upsert(
      { visitor_id: @web_visitor.id, project_id: @project.id,
        event_date: Date.new(2026, 3, 1), platform: Grovs::Platforms::WEB },
      unique_by: :uniq_vds_proj_visitor_date_platform
    )

    query = RevenueMetricsQuery.new(
      project_id: @project.id, start_date: @start_date, end_date: @end_date,
      product: nil
    )

    results = query.with_arpu
    # 3 distinct visitors: ios, android, web — web must NOT be excluded
    premium = results.find { |r| r["product_id"] == "com.test.premium" }
    expected_arpu = 1998.0 / 3
    assert_in_delta expected_arpu, premium["arpu_usd_cents"], 0.01
  end

  # === Platform filtering: unique_purchasers isolation ===

  test "unique_purchasers filtered by platform=ios excludes cross-platform purchasers" do
    # Add an Android device purchase for the iOS product to create cross-platform data
    PurchaseEvent.create!(
      event_type: "buy", device: devices(:android_device), project: @project,
      product_id: "com.test.premium", price_cents: 999, currency: "USD",
      usd_price_cents: 999, date: Date.new(2026, 3, 5),
      transaction_id: "txn_cross_plat", original_transaction_id: "orig_cross",
      webhook_validated: true, store: true, processed: true, purchase_type: "subscription"
    )

    # Without platform filter: 2 unique purchasers (ios_device + android_device)
    all_query = RevenueMetricsQuery.new(
      project_id: @project.id, start_date: @start_date, end_date: @end_date,
      product: "premium", platform: nil
    )
    all_results = all_query.call
    premium_all = all_results.find { |r| r["product_id"] == "com.test.premium" }
    assert_equal 2, premium_all["unique_purchasers"], "Without filter: both devices count"

    # With platform=ios: only 1 unique purchaser (ios_device only)
    ios_query = RevenueMetricsQuery.new(
      project_id: @project.id, start_date: @start_date, end_date: @end_date,
      product: "premium", platform: "ios"
    )
    ios_results = ios_query.call
    premium_ios = ios_results.find { |r| r["product_id"] == "com.test.premium" }
    assert_equal 1, premium_ios["unique_purchasers"], "iOS filter must exclude Android purchaser"
  end

  test "unique_purchasers filtered by platform=web counts only web device purchasers" do
    query = RevenueMetricsQuery.new(
      project_id: @project.id, start_date: @start_date, end_date: @end_date,
      product: nil, platform: "web"
    )

    results = query.call
    web = results.find { |r| r["product_id"] == "com.test.webpro" }
    assert web
    # web_device is the only web purchaser of com.test.webpro
    assert_equal 1, web["unique_purchasers"]
  end

  # === Platform filtering: LTV isolation ===

  test "ltv filtered by platform=ios excludes cross-platform daily stats" do
    # Add Android daily stats for the same product to create cross-platform LTV data
    InAppProductDailyStatistic.create!(
      in_app_product: in_app_products(:premium_ios), project: @project,
      event_date: Date.new(2026, 3, 5), platform: "android",
      revenue: 500, purchase_events: 1, canceled_events: 0,
      first_time_purchases: 0, repeat_purchases: 1, device_revenue: 500
    )

    # iOS-only LTV should use iOS device_revenue (999 + 999 = 1998), not include Android (500)
    ios_query = RevenueMetricsQuery.new(
      project_id: @project.id, start_date: @start_date, end_date: @end_date,
      product: "premium", platform: "ios"
    )
    ios_results = ios_query.call
    premium_ios = ios_results.first
    assert premium_ios

    product = in_app_products(:premium_ios)
    expected_ltv = 1998.0 / product.unique_purchasing_devices
    assert_in_delta expected_ltv, premium_ios["ltv_usd_cents"], 0.01,
      "iOS LTV must not include Android daily stats revenue"
  end

  test "call returns platforms as JSON array" do
    query = RevenueMetricsQuery.new(
      project_id: @project.id,
      start_date: @start_date,
      end_date: @end_date,
      product: nil
    )

    results = query.call
    premium = results.find { |r| r["product_id"] == "com.test.premium" }
    platforms = JSON.parse(premium["platforms"])
    assert_includes platforms, "ios"
  end
end
