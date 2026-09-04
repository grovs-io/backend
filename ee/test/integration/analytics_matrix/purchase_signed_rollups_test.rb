# frozen_string_literal: true

require "test_helper"

# The CH purchase rollups must be EXACT + SIGNED, matching PG's source of truth
# PurchaseEvent#revenue_delta / units_sold. Asserts the signing multiIf via the
# MV + ReplacingMergeTree dedup. Run with GROVS_EE=true.
class PurchaseSignedRollupsTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  PURCHASE_DATE = '2026-04-01'
  PROJECT_ID = 4242

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
  end

  # Inserts a raw purchase_events row (triggers both signed MVs).
  def insert_purchase(attrs = {})
    defaults = {
      project_id: PROJECT_ID,
      event_type: 'buy',
      purchase_type: 'subscription',
      product_id: 'p.main',
      usd_price_cents: 1000,
      currency: 'USD',
      quantity: 1,
      transaction_id: "txn_#{SecureRandom.hex(6)}",
      original_transaction_id: '',
      store_source: 'apple',
      device_id: 1,
      link_id: 0,
      visitor_id: 1,
      purchase_date: "#{PURCHASE_DATE} 10:00:00.000",
      created_at: "#{PURCHASE_DATE} 10:00:00.000"
    }
    Clickhouse.with { |conn| conn.insert('purchase_events', [defaults.merge(attrs)]) }
  end

  def project_revenue(event_type)
    Clickhouse.with do |c|
      c.select_value(
        "SELECT sum(total_revenue_cents) FROM purchase_project_daily FINAL " \
        "WHERE project_id = #{PROJECT_ID} AND event_type = '#{event_type}'"
      ).to_i
    end
  end

  def project_units(event_type)
    Clickhouse.with do |c|
      c.select_value(
        "SELECT sum(units) FROM purchase_project_daily FINAL " \
        "WHERE project_id = #{PROJECT_ID} AND event_type = '#{event_type}'"
      ).to_i
    end
  end

  def product_revenue(product_id)
    Clickhouse.with do |c|
      c.select_value(
        "SELECT sum(total_revenue_cents) FROM purchase_product_daily FINAL " \
        "WHERE project_id = #{PROJECT_ID} AND product_id = '#{product_id}'"
      ).to_i
    end
  end

  def product_units(product_id)
    Clickhouse.with do |c|
      c.select_value(
        "SELECT sum(units) FROM purchase_product_daily FINAL " \
        "WHERE project_id = #{PROJECT_ID} AND product_id = '#{product_id}'"
      ).to_i
    end
  end

  test "buy is positive revenue and counts units" do
    insert_purchase(event_type: 'buy', usd_price_cents: 1000)
    assert_equal 1000, project_revenue('buy')
    assert_equal 1, project_units('buy')
  end

  test "refund is negative revenue and zero units" do
    insert_purchase(event_type: 'refund', purchase_type: 'one_time', usd_price_cents: 300)
    assert_equal(-300, project_revenue('refund'))
    assert_equal 0, project_units('refund')
  end

  test "one_time cancel is negative revenue" do
    insert_purchase(event_type: 'cancel', purchase_type: 'one_time', usd_price_cents: 200)
    assert_equal(-200, project_revenue('cancel'))
    assert_equal 0, project_units('cancel')
  end

  test "subscription cancel contributes zero revenue" do
    insert_purchase(event_type: 'cancel', purchase_type: 'subscription', usd_price_cents: 700)
    assert_equal 0, project_revenue('cancel')
    assert_equal 0, project_units('cancel')
  end

  test "refund_reversed is positive revenue and counts units" do
    insert_purchase(event_type: 'refund_reversed', purchase_type: 'subscription', usd_price_cents: 500)
    assert_equal 500, project_revenue('refund_reversed')
    assert_equal 1, project_units('refund_reversed')
  end

  test "subscription refund is negative revenue (refund signs regardless of type)" do
    insert_purchase(event_type: 'refund', purchase_type: 'subscription', usd_price_cents: 400)
    assert_equal(-400, project_revenue('refund'))
  end

  test "quantity multiplies signed revenue and units" do
    insert_purchase(event_type: 'buy', usd_price_cents: 1000, quantity: 3)
    assert_equal 3000, project_revenue('buy')
    assert_equal 3, project_units('buy')

    insert_purchase(event_type: 'refund', purchase_type: 'one_time', usd_price_cents: 100, quantity: 2)
    assert_equal(-200, project_revenue('refund'))
  end

  test "zero cents yields zero revenue" do
    insert_purchase(event_type: 'buy', usd_price_cents: 0, quantity: 5)
    assert_equal 0, project_revenue('buy')
    assert_equal 5, project_units('buy'), "units still count for a zero-price buy"
  end

  test "product rollup is signed and quantity weighted" do
    insert_purchase(event_type: 'buy', product_id: 'p.bundle', usd_price_cents: 1000, quantity: 2)
    insert_purchase(event_type: 'refund', purchase_type: 'one_time', product_id: 'p.bundle', usd_price_cents: 300, quantity: 1)
    assert_equal 1700, product_revenue('p.bundle'), "2000 buy - 300 refund"
    assert_equal 2, product_units('p.bundle'), "only the buy counts units"
  end

  test "replaying same transaction does not double count project rollup" do
    txn = 'txn_replay_proj'
    insert_purchase(event_type: 'buy', transaction_id: txn, usd_price_cents: 800)
    insert_purchase(event_type: 'buy', transaction_id: txn, usd_price_cents: 800)
    assert_equal 800, project_revenue('buy'), "ReplacingMergeTree + FINAL keeps one row"
    assert_equal 1, project_units('buy')
  end

  test "replaying same transaction does not double count product rollup" do
    txn = 'txn_replay_prod'
    insert_purchase(event_type: 'buy', transaction_id: txn, product_id: 'p.dup', usd_price_cents: 600)
    insert_purchase(event_type: 'buy', transaction_id: txn, product_id: 'p.dup', usd_price_cents: 600)
    assert_equal 600, product_revenue('p.dup')
    assert_equal 1, product_units('p.dup')
  end

  test "later correction supersedes earlier price in product rollup" do
    txn = 'txn_corr_prod'
    insert_purchase(event_type: 'buy', transaction_id: txn, product_id: 'p.corr',
                    usd_price_cents: 900, created_at: "#{PURCHASE_DATE} 10:00:00.000")
    insert_purchase(event_type: 'buy', transaction_id: txn, product_id: 'p.corr',
                    usd_price_cents: 1400, created_at: "#{PURCHASE_DATE} 11:00:00.000")
    assert_equal 1400, product_revenue('p.corr'), "FINAL keeps the newest version"
  end
end
