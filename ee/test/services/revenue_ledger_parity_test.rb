# frozen_string_literal: true

require "test_helper"

# Executable parity contract: events processed through the REAL pipeline must
# produce identical revenue under RevenueLedgerQuery and the legacy stat tables.
class RevenueLedgerParityTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :domains, :links, :redirect_configs,
           :in_app_products, :in_app_product_daily_statistics

  RANGE = { start_date: Date.new(2026, 6, 20), end_date: Date.new(2026, 6, 22) }.freeze

  setup do
    @project = projects(:one)
    @job = ProcessPurchaseEventJob.new
    [DailyProjectMetric, VisitorDailyStatistic, LinkDailyStatistic].each do |m|
      m.where(project_id: @project.id).delete_all
    end
  end

  test "ledger reads equal stat-table sums for a processed event matrix" do
    process(event_type: "buy", usd: 999, qty: 2, device: devices(:ios_device),
            link: links(:basic_link), store_source: "google", purchase_type: "subscription",
            date: Time.utc(2026, 6, 20, 10))
    process(event_type: "buy", usd: 250, device: devices(:android_device),
            purchase_type: "one_time", date: Time.utc(2026, 6, 21, 8))
    process(event_type: "refund", usd: 250, device: devices(:android_device),
            purchase_type: "one_time", date: Time.utc(2026, 6, 21, 9))
    process(event_type: "cancel", usd: 999, device: devices(:ios_device),
            store_source: "google", purchase_type: "subscription", date: Time.utc(2026, 6, 22, 7))
    process(event_type: "buy", usd: 400, device: nil, store_source: "apple",
            purchase_type: "one_time", date: Time.utc(2026, 6, 22, 12)) # device-less webhook

    ledger = RevenueLedgerQuery.project_totals(@project.id, **RANGE)
    stats = DailyProjectMetric.where(project_id: @project.id, event_date: RANGE[:start_date]..RANGE[:end_date])
    assert_equal stats.sum(:revenue), ledger[:revenue]
    assert_equal stats.sum(:units_sold), ledger[:units_sold]
    assert_equal stats.sum(:cancellations), ledger[:cancellations]

    ios = visitors(:ios_visitor)
    ledger_visitors = RevenueLedgerQuery.by_visitor_ids(@project.id, visitor_ids: [ios.id], **RANGE)
    stat_visitor = VisitorDailyStatistic.where(project_id: @project.id, visitor_id: ios.id,
                                               event_date: RANGE[:start_date]..RANGE[:end_date]).sum(:revenue)
    assert_equal stat_visitor, ledger_visitors.fetch(ios.id, 0)

    link = links(:basic_link)
    ledger_links = RevenueLedgerQuery.by_link_ids(@project.id, link_ids: [link.id], **RANGE)
    stat_link = LinkDailyStatistic.where(project_id: @project.id, link_id: link.id,
                                         event_date: RANGE[:start_date]..RANGE[:end_date]).sum(:revenue)
    assert_equal stat_link, ledger_links.fetch(link.id, 0)

    series = RevenueLedgerQuery.daily_series(@project.id, **RANGE)
    DailyProjectMetric.where(project_id: @project.id, event_date: RANGE[:start_date]..RANGE[:end_date])
                      .group(:event_date).sum(:revenue).each do |day, cents|
      assert_equal cents, series.fetch(day, 0), "daily series diverges on #{day}"
    end

    per_platform = RevenueLedgerQuery.project_totals(@project.id, **RANGE, platform: "android")
    stat_android = DailyProjectMetric.where(project_id: @project.id, platform: "android",
                                            event_date: RANGE[:start_date]..RANGE[:end_date]).sum(:revenue)
    assert_equal stat_android, per_platform[:revenue], "platform-filtered parity via revenue_platform"
  end

  private

  def process(event_type:, usd:, device:, purchase_type:, date:, qty: 1, link: nil, store_source: nil)
    event = PurchaseEvent.create!(
      project: @project, event_type: event_type, usd_price_cents: usd, quantity: qty,
      device: device, link: link, purchase_type: purchase_type, date: date,
      store_source: store_source, store: store_source.present?, webhook_validated: store_source.present?,
      product_id: "com.test.parity", transaction_id: "rlp_#{SecureRandom.hex(5)}"
    )
    @job.perform(event.id)
    event
  end
end
