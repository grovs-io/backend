# frozen_string_literal: true

require "test_helper"

class PurchaseLedgerContractTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :domains, :links,
           :purchase_events, :in_app_products, :in_app_product_daily_statistics,
           :subscription_states

  setup do
    skip_unless_clickhouse!

    @project = projects(:one)
    @device = devices(:ios_device)
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)
    @job = ProcessPurchaseEventJob.new
    @event_date = Date.new(2026, 6, 23)

    @original_ch_enabled = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true

    reset_purchase_stats!
  end

  teardown do
    Rails.application.config.clickhouse_write_enabled = @original_ch_enabled if defined?(@original_ch_enabled)
  end

  test "every purchase event type has consistent Postgres processing, ClickHouse row, and project metric impact" do
    events = Grovs::Purchases::ALL_EVENTS.each_with_index.map do |event_type, index|
      create_purchase_event(event_type, index)
    end

    events.each { |event| @job.perform(event.id) }

    events.each do |event|
      event.reload
      assert event.processed?, "#{event.event_type} should be marked processed in Postgres"

      row = ch_purchase_row(event)
      assert row, "missing ClickHouse purchase row for #{event.event_type}"
      assert_equal event.project_id, row["project_id"]
      assert_equal event.event_type, row["event_type"]
      assert_equal event.purchase_type, row["purchase_type"]
      assert_equal event.product_id, row["product_id"]
      assert_equal event.usd_price_cents, row["usd_price_cents"]
      assert_equal event.currency, row["currency"]
      assert_equal event.quantity, row["quantity"]
      assert_equal event.transaction_id, row["transaction_id"]
      assert_equal event.original_transaction_id, row["original_transaction_id"]
      assert_equal event.store_source, row["store_source"]
      assert_equal @device.id, row["device_id"]
      assert_equal @visitor.id, row["visitor_id"]
      assert_equal @link.id, row["link_id"]
    end

    metric = DailyProjectMetric.find_by!(project_id: @project.id, event_date: @event_date, platform: Grovs::Platforms::IOS)
    assert_equal 100, metric.revenue
    assert_equal 2, metric.units_sold
    assert_equal 2, metric.cancellations
  end

  private

  def create_purchase_event(event_type, index)
    PurchaseEvent.create!(
      event_type: event_type,
      device: @device,
      link: @link,
      project: @project,
      identifier: "ledger.purchase.#{event_type}",
      price_cents: 100,
      currency: "USD",
      usd_price_cents: 100,
      quantity: 1,
      date: @event_date.to_time(:utc) + index.minutes,
      transaction_id: "ledger_txn_#{event_type}",
      original_transaction_id: "ledger_orig_#{event_type}",
      product_id: "ledger_product_#{event_type}",
      webhook_validated: true,
      store: true,
      purchase_type: purchase_type_for(event_type),
      store_source: Grovs::Webhooks::APPLE
    )
  end

  def purchase_type_for(event_type)
    event_type == Grovs::Purchases::EVENT_CANCEL ? Grovs::Purchases::TYPE_SUBSCRIPTION : Grovs::Purchases::TYPE_ONE_TIME
  end

  def ch_purchase_row(event)
    escaped_transaction_id = event.transaction_id.gsub("'", "''")
    ch_query("purchase_events", @project.id, extra_where: "transaction_id = '#{escaped_transaction_id}'").first
  end

  def reset_purchase_stats!
    DailyProjectMetric.where(project_id: @project.id, event_date: @event_date).delete_all
    InAppProductDailyStatistic.where(project_id: @project.id, event_date: @event_date).delete_all
  end
end
