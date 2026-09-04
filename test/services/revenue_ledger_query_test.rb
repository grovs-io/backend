# frozen_string_literal: true

require "test_helper"

class RevenueLedgerQueryTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :domains, :links, :redirect_configs, :campaigns

  RANGE = { start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 2) }.freeze

  setup do
    @project = projects(:one)
    @link = links(:basic_link)
    @visitor = visitors(:ios_visitor)
    PurchaseEvent.delete_all # fixture rows from other classes persist outside transactions
  end

  # --- signed math (mirrors PurchaseEvent#revenue_delta) ---

  test "buy and refund_reversed add, refund subtracts, quantity-weighted" do
    ledger_row(usd: 100, qty: 3)
    ledger_row(event_type: "refund_reversed", usd: 50)
    ledger_row(event_type: "refund", usd: 40)

    assert_equal({ revenue: 310, units_sold: 4, cancellations: 1 }, totals)
  end

  test "cancel subtracts for one_time but is revenue-neutral for subscriptions" do
    ledger_row(usd: 100)
    ledger_row(event_type: "cancel", purchase_type: "one_time", usd: 30)
    ledger_row(event_type: "cancel", purchase_type: "subscription", usd: 999)

    assert_equal 70, totals[:revenue]
    assert_equal 2, totals[:cancellations], "subscription cancel still counts as a cancellation"
  end

  test "cancel with NULL purchase_type subtracts (IS DISTINCT FROM semantics)" do
    ledger_row(usd: 100)
    ledger_row(event_type: "cancel", purchase_type: nil, usd: 25)

    assert_equal 75, totals[:revenue]
  end

  test "nil usd_price_cents contributes zero revenue but still counts units" do
    ledger_row(usd: nil, qty: 2)

    assert_equal({ revenue: 0, units_sold: 2, cancellations: 0 }, totals)
  end

  # --- inclusion gate ---

  test "unprocessed, out-of-range and foreign-project rows are excluded" do
    ledger_row(usd: 100)
    ledger_row(usd: 999, processed: false)
    ledger_row(usd: 999, date: Time.utc(2026, 4, 9))
    ledger_row(usd: 999, project: projects(:two))

    assert_equal 100, totals[:revenue]
  end

  test "platform filter uses the persisted revenue_platform snapshot" do
    ledger_row(usd: 100, platform: "ios")
    ledger_row(usd: 40, platform: "android")

    assert_equal 100, RevenueLedgerQuery.project_totals(@project.id, **RANGE, platform: "ios")[:revenue]
    assert_equal 140, totals[:revenue]
  end

  # --- grains ---

  test "by_link_ids and revenue_by_link group per link, excluding unattributed" do
    ledger_row(usd: 100, link: @link)
    ledger_row(usd: 50, link: links(:campaign_link))
    ledger_row(usd: 999, link: nil)

    assert_equal({ @link.id => 100 }, RevenueLedgerQuery.by_link_ids(@project.id, link_ids: [@link.id], **RANGE))
    assert_equal({ @link.id => 100, links(:campaign_link).id => 50 },
                 RevenueLedgerQuery.revenue_by_link(@project.id, **RANGE))
  end

  test "by_visitor_ids and revenue_by_visitor group per visitor" do
    ledger_row(usd: 100, visitor: @visitor)
    ledger_row(event_type: "refund", usd: 30, visitor: @visitor)
    ledger_row(usd: 5, visitor: visitors(:android_visitor))

    assert_equal({ @visitor.id => 70 },
                 RevenueLedgerQuery.by_visitor_ids(@project.id, visitor_ids: [@visitor.id], **RANGE))
    assert_equal({ @visitor.id => 70, visitors(:android_visitor).id => 5 },
                 RevenueLedgerQuery.revenue_by_visitor(@project.id, **RANGE))
  end

  test "by_campaigns aggregates through the current links.campaign_id mapping" do
    @link.update!(campaign: campaigns(:one))
    ledger_row(usd: 100, link: @link)
    ledger_row(usd: 999, link: links(:no_custom_redirect_link)) # no campaign

    assert_equal({ campaigns(:one).id => 100 },
                 RevenueLedgerQuery.by_campaigns(@project.id, campaign_ids: [campaigns(:one).id], **RANGE))
  end

  test "by_inviter sums invited visitors' purchases under the inviter" do
    visitors(:android_visitor).update!(inviter_id: @visitor.id)
    ledger_row(usd: 100, visitor: visitors(:android_visitor))
    ledger_row(usd: 999, visitor: @visitor) # own purchase, not invited revenue

    assert_equal({ @visitor.id => 100 },
                 RevenueLedgerQuery.by_inviter(@project.id, inviter_ids: [@visitor.id], **RANGE))
  end

  test "daily_series buckets on the ledger date" do
    ledger_row(usd: 100, date: Time.utc(2026, 3, 1, 5))
    ledger_row(usd: 40, date: Time.utc(2026, 3, 2, 23))

    assert_equal({ Date.new(2026, 3, 1) => 100, Date.new(2026, 3, 2) => 40 },
                 RevenueLedgerQuery.daily_series(@project.id, **RANGE))
  end

  test "first_time_purchases counts event-time earliest buys, late rows reclassify" do
    d1 = devices(:ios_device)
    d2 = devices(:android_device)
    first_row = ledger_row(usd: 10, date: Time.utc(2026, 3, 1, 8))
    first_row.update_columns(device_id: d1.id, product_id: "com.p")
    repeat_row = ledger_row(usd: 10, date: Time.utc(2026, 3, 2, 8))
    repeat_row.update_columns(device_id: d1.id, product_id: "com.p")
    other_first = ledger_row(usd: 10, date: Time.utc(2026, 3, 2, 9), platform: "android")
    other_first.update_columns(device_id: d2.id, product_id: "com.p")
    # An OLDER event for d1 arriving late (processed later) still wins by event time.
    late_older = ledger_row(usd: 10, date: Time.utc(2026, 2, 20, 8))
    late_older.update_columns(device_id: d1.id, product_id: "com.p")

    assert_equal 1, RevenueLedgerQuery.first_time_purchases(@project.id, **RANGE),
                 "d1's true first (Feb 20) is out of range; only d2's first counts"
    assert_equal 1, RevenueLedgerQuery.first_time_purchases(@project.id, **RANGE, platform: "android")
    assert_equal 0, RevenueLedgerQuery.first_time_purchases(@project.id, **RANGE, platform: "ios")
  end

  test "blank product ids never classify as first purchases (and cannot double-partition)" do
    nil_prod = ledger_row(usd: 10)
    nil_prod.update_columns(device_id: devices(:ios_device).id, product_id: nil)
    blank_prod = ledger_row(usd: 10, date: Time.utc(2026, 3, 2, 8))
    blank_prod.update_columns(device_id: devices(:ios_device).id, product_id: "")

    assert_equal 0, RevenueLedgerQuery.first_time_purchases(@project.id, **RANGE)
  end

  # --- failure semantics ---

  test "query failure returns nil, empty result returns a real zero" do
    assert_equal({ revenue: 0, units_sold: 0, cancellations: 0 }, totals)
    assert_equal({}, RevenueLedgerQuery.revenue_by_link(@project.id, **RANGE))

    PurchaseEvent.stub(:where, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_nil RevenueLedgerQuery.project_totals(@project.id, **RANGE)
      assert_nil RevenueLedgerQuery.revenue_by_link(@project.id, **RANGE)
      assert_nil RevenueLedgerQuery.daily_series(@project.id, **RANGE)
    end
  end

  private

  def totals
    RevenueLedgerQuery.project_totals(@project.id, **RANGE)
  end

  def ledger_row(event_type: "buy", usd: 100, qty: 1, purchase_type: "one_time",
                 date: Time.utc(2026, 3, 1, 12), platform: "ios", link: nil, visitor: nil,
                 processed: true, project: @project)
    pe = PurchaseEvent.create!(
      project: project, event_type: event_type, usd_price_cents: usd, quantity: qty,
      purchase_type: purchase_type, date: date, processed: processed, link_id: link&.id,
      transaction_id: "rlq_#{SecureRandom.hex(5)}"
    )
    pe.update_columns(revenue_platform: platform, visitor_id: visitor&.id)
    pe
  end
end
