# frozen_string_literal: true

require "test_helper"
require "sidekiq/testing"

# EE: purchase revenue attribution into link/campaign rollups. Revenue (signed)
# goes to LinkDailyStatistic for event.link_id; campaign revenue = PG sum of its
# links (CampaignStatisticsQuery). No CH campaign-revenue surface.
class LinkCampaignPurchaseMatrixTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :domains, :redirect_configs,
           :in_app_products, :in_app_product_daily_statistics, :subscription_states

  PURCHASE_DATE = Date.current

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @orig_ch_write = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true
    truncate_clickhouse_tables
    [PurchaseEvent, DailyProjectMetric, LinkDailyStatistic, VisitorDailyStatistic].each do |m|
      m.where(project_id: @project.id).delete_all
    end
    @campaign_a = Campaign.create!(project: @project, name: "Campaign A", archived: false)
    @link_a1 = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one), campaign: @campaign_a,
      path: "lcp-a1", title: "A1", generated_from_platform: "ios", active: true,
      sdk_generated: false, data: "[]"
    )
  end

  teardown do
    Rails.application.config.clickhouse_write_enabled = @orig_ch_write if defined?(@orig_ch_write)
  end

  def create_purchase(link:, usd:, type: Grovs::Purchases::EVENT_BUY, ptype: Grovs::Purchases::TYPE_ONE_TIME)
    PurchaseEvent.create!(
      event_type: type, project: @project, device: devices(:ios_device), link: link,
      identifier: "com.test.app", price_cents: usd, currency: "USD", usd_price_cents: usd,
      date: PURCHASE_DATE.to_time(:utc) + 10.hours,
      transaction_id: "txn_#{SecureRandom.hex(6)}", original_transaction_id: "orig_#{SecureRandom.hex(6)}",
      product_id: "com.test.premium", webhook_validated: true, store: true, processed: false,
      purchase_type: ptype, store_source: Grovs::Webhooks::APPLE
    )
  end

  def campaign_revenue(campaign)
    CampaignStatisticsQuery.new(project: @project, params: { start_date: PURCHASE_DATE, end_date: PURCHASE_DATE })
                           .call.find { |c| c.id == campaign.id }.total_revenue.to_i
  end

  def ch_purchase_row(transaction_id)
    ch_query("purchase_events", @project.id, extra_where: "transaction_id = '#{transaction_id}'").first
  end

  test "a purchase with a link flows revenue into link and campaign" do
    event = create_purchase(link: @link_a1, usd: 1499)
    ProcessPurchaseEventJob.new.perform(event.id)

    assert_equal @link_a1.id, event.reload.link_id
    assert_equal @link_a1.id, ch_purchase_row(event.transaction_id)["link_id"].to_i
    assert_equal 1499, LinkDailyStatistic.where(project_id: @project.id, link_id: @link_a1.id).sum(:revenue)
    assert_equal 1499, campaign_revenue(@campaign_a), "campaign revenue = sum of its links' revenue"
  end

  test "a refund nets link and campaign revenue back to zero (CH gross rows remain)" do
    buy = create_purchase(link: @link_a1, usd: 1000, type: Grovs::Purchases::EVENT_BUY)
    ProcessPurchaseEventJob.new.perform(buy.id)
    refund = create_purchase(link: @link_a1, usd: 1000, type: Grovs::Purchases::EVENT_REFUND)
    ProcessPurchaseEventJob.new.perform(refund.id)

    assert_equal 0, LinkDailyStatistic.where(project_id: @project.id, link_id: @link_a1.id).sum(:revenue)
    assert_equal 0, campaign_revenue(@campaign_a)
    # gross CH rows still exist by type
    assert_equal 1, ch_query("purchase_events", @project.id, extra_where: "event_type = 'buy'").size
    assert_equal 1, ch_query("purchase_events", @project.id, extra_where: "event_type = 'refund'").size
  end

  test "a purchase without a link leaves link/campaign revenue untouched" do
    event = create_purchase(link: nil, usd: 2000)
    ProcessPurchaseEventJob.new.perform(event.id)

    assert_equal 0, LinkDailyStatistic.where(project_id: @project.id).sum(:revenue), "no link revenue"
    assert_equal 0, campaign_revenue(@campaign_a)
    # ...but project-level revenue still moved
    assert_equal 2000, DailyProjectMetric.where(project_id: @project.id).sum(:revenue)
  end

  # Last-touch attribution: the SDK/custom purchase path (SdkPaymentService) sets
  # link_id from VisitorLastVisit — unlike the Apple/Google WEBHOOK path, which
  # attributes via SubscriptionState/PurchaseEvent by original_transaction_id.
  # So an SDK purchase with no explicit link inherits the visitor's last-clicked
  # link, and revenue flows to that link/campaign.
  test "SDK last-touch attribution routes revenue to the visitor's last link" do
    visitor = visitors(:ios_visitor)
    VisitorLastVisit.create!(project: @project, visitor: visitor, link: @link_a1)
    @project.instance.update!(revenue_collection_enabled: true)

    # Fully async: a store:false SDK event enqueues ProcessPurchaseEventJob directly
    # (sdk_payment_service.rb:111). inline! runs that enqueued job for real — no
    # manual perform — so this exercises create → enqueue → process end to end.
    Sidekiq::Testing.inline! do
      SdkPaymentService.new(
        project: @project, device: devices(:ios_device), visitor: visitor,
        platform: "ios", identifier: "com.test.app"
      ).create_or_update(event_params: {
        event_type: Grovs::Purchases::EVENT_BUY, price_cents: 750, currency: "USD",
        transaction_id: "sdk_#{SecureRandom.hex(6)}", product_id: "com.test.premium",
        date: PURCHASE_DATE.to_time(:utc) + 10.hours, store: false,
        purchase_type: Grovs::Purchases::TYPE_ONE_TIME
      })
    end

    event = PurchaseEvent.where(project_id: @project.id).order(:created_at).last
    assert_equal @link_a1.id, event.link_id, "SDK purchase inherits the last-touch link"
    assert event.processed?, "the enqueued ProcessPurchaseEventJob ran end to end"
    assert_equal 750, LinkDailyStatistic.where(project_id: @project.id, link_id: @link_a1.id).sum(:revenue)
    assert_equal 750, campaign_revenue(@campaign_a), "last-touch revenue rolls up to the campaign"
  end
end
