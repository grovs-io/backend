# frozen_string_literal: true

require "test_helper"

class ClickhousePrimaryGuardTest < ActiveSupport::TestCase
  CH_OUTAGE = "Code: 210. DB::NetException: Connection refused. (NETWORK_ERROR)"
  CH_DEFECT = "Code: 47. DB::Exception: Unknown identifier foo"

  test "primary? reflects config flag" do
    prev = Rails.application.config.clickhouse_primary
    Rails.application.config.clickhouse_primary = true
    assert Clickhouse.primary?
  ensure
    Rails.application.config.clickhouse_primary = prev
  end

  test "boot guard refuses primary without write plus read enabled" do
    assert_not Clickhouse.primary_allowed?(primary: true, write: false, read: true)
    assert_not Clickhouse.primary_allowed?(primary: true, write: true, read: false)
    assert_not Clickhouse.primary_allowed?(primary: true, write: false, read: false)
    assert Clickhouse.primary_allowed?(primary: true, write: true, read: true)
    assert_not Clickhouse.primary_allowed?(primary: false, write: true, read: true)
  end

  test "metered primary boot fails unless the MAU chain is structurally wired to CH" do
    error = assert_raises(RuntimeError) do
      Clickhouse.validate_primary_billing_wiring!(primary: true, self_hosted: false, mau_source: :postgres)
    end
    assert_match(/MAU_SOURCE/, error.message)
  end

  test "billing wiring gate passes for wired metered primary and all unmetered combos" do
    assert_nil Clickhouse.validate_primary_billing_wiring!(primary: true, self_hosted: false, mau_source: :clickhouse)
    # self-hosted is unmetered — never gated, wired or not
    assert_nil Clickhouse.validate_primary_billing_wiring!(primary: true, self_hosted: true, mau_source: :postgres)
    # not primary — PG billing stays valid
    assert_nil Clickhouse.validate_primary_billing_wiring!(primary: false, self_hosted: false, mau_source: :postgres)
  end

  test "the shipped MAU_SOURCE constant satisfies the boot gate" do
    assert_equal :clickhouse, ProjectService::MAU_SOURCE
  end

  test "primary implies the rollup and ledger read flags but never attribution" do
    clear_own_read_flags
    Rails.application.config.clickhouse_primary = true

    assert Clickhouse.analytics_rollups_read_enabled?
    assert RevenueLedger.reads_enabled?
    assert_not Clickhouse.attribution_read_enabled?
  end

  test "without primary the three read flags stay independent" do
    clear_own_read_flags

    assert_not Clickhouse.analytics_rollups_read_enabled?
    assert_not Clickhouse.attribution_read_enabled?
    assert_not RevenueLedger.reads_enabled?

    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    Rails.application.config.clickhouse_attribution_read_enabled = true
    Rails.application.config.revenue_reads_from_ledger = true

    assert Clickhouse.analytics_rollups_read_enabled?
    assert Clickhouse.attribution_read_enabled?
    assert RevenueLedger.reads_enabled?
  end

  test "unavailable! is a no-op off primary and raises with the surface on primary" do
    assert_nil Clickhouse.unavailable!("top_links")

    Rails.application.config.clickhouse_primary = true

    error = assert_raises(Clickhouse::Unavailable) { Clickhouse.unavailable!("top_links", IOError.new) }
    assert_match(/top_links/, error.message)
    assert_match(/IOError/, error.message)
  end

  test "a failed CH read falls back off primary and raises under primary" do
    boom = ->(*) { raise ClickHouse::Client::DatabaseError, CH_OUTAGE }

    Clickhouse.stub(:with, boom) do
      assert_nil ClickhouseReadService.top_link_metrics(1, link_ids: [1], start_date: "2026-01-01",
                                                          end_date: "2026-01-02")

      Rails.application.config.clickhouse_primary = true
      assert_raises(Clickhouse::Unavailable) do
        ClickhouseReadService.top_link_metrics(1, link_ids: [1], start_date: "2026-01-01", end_date: "2026-01-02")
      end
    end
  end

  test "billing-only reads never raise under primary" do
    boom = ->(*) { raise ClickHouse::Client::DatabaseError, CH_OUTAGE }
    Rails.application.config.clickhouse_primary = true

    Clickhouse.stub(:with, boom) do
      assert_nil ClickhouseReadService.billing_active_visitors_exact([1], start_date: "2026-01-01",
                                                                         end_date: "2026-01-02")

      # Shared with DashboardMetrics and the purchases screen, so it must NOT be soft.
      assert_raises(Clickhouse::Unavailable) do
        ClickhouseReadService.billing_active_visitors([1], start_date: "2026-01-01", end_date: "2026-01-02")
      end
    end
  end

  # DatabaseError carries both outages and defects; query_helpers_test.rb:699 already pins
  # "Unknown identifier is a genuine bug not masked" — primary must not undo that.
  test "a DatabaseError is an outage only when its ClickHouse code says so" do
    Rails.application.config.clickhouse_primary = true

    Clickhouse.stub(:with, ->(*) { raise ClickHouse::Client::DatabaseError, CH_OUTAGE }) do
      assert_raises(Clickhouse::Unavailable) { ClickhouseReadService.event_filter_values(1) }
    end

    Clickhouse.stub(:with, ->(*) { raise ClickHouse::Client::DatabaseError, CH_DEFECT }) do
      error = assert_raises(ClickHouse::Client::DatabaseError) { ClickhouseReadService.event_filter_values(1) }
      assert_match(/Unknown identifier/, error.message)
    end
  end

  # click_house-client raises DatabaseError with the response body alone, so a proxy answering
  # for a down CH carries no ClickHouse code at all.
  test "a proxy or empty body is an outage, not a code defect" do
    Rails.application.config.clickhouse_primary = true

    ["<html><head><title>502 Bad Gateway</title></head></html>", "", "upstream connect error"].each do |body|
      Clickhouse.stub(:with, ->(*) { raise ClickHouse::Client::DatabaseError, body }) do
        assert_raises(Clickhouse::Unavailable, "body #{body.inspect} must read as an outage") do
          ClickhouseReadService.event_filter_values(1)
        end
      end
    end
  end

  test "a transport failure is always an outage under primary" do
    Rails.application.config.clickhouse_primary = true

    Clickhouse.stub(:with, ->(*) { raise Net::OpenTimeout, "execution expired" }) do
      assert_raises(Clickhouse::Unavailable) { ClickhouseReadService.event_filter_values(1) }
    end
  end

  test "a code defect surfaces as itself, not as a ClickHouse outage" do
    Rails.application.config.clickhouse_primary = true
    bug = ->(*) { raise NoMethodError, "undefined method for nil" }

    Clickhouse.stub(:with, bug) do
      assert_raises(NoMethodError) do
        ClickhouseReadService.top_link_metrics(1, link_ids: [1], start_date: "2026-01-01", end_date: "2026-01-02")
      end
    end

    Rails.application.config.clickhouse_primary = false
    Clickhouse.stub(:with, bug) do
      assert_nil ClickhouseReadService.top_link_metrics(1, link_ids: [1], start_date: "2026-01-01",
                                                          end_date: "2026-01-02")
    end
  end

  # One case per reader family: a CH outage must never resolve to a Postgres or empty answer.
  PRIMARY_STRICT_READS = {
    top_link_metrics: -> { ClickhouseReadService.top_link_metrics(1, link_ids: [1], start_date: "2026-01-01", end_date: "2026-01-02") },
    project_metrics_daily_totals: -> { ClickhouseReadService.project_metrics_daily_totals(1, start_date: "2026-01-01", end_date: "2026-01-02") },
    organic_users_total: -> { ClickhouseReadService.organic_users_total(1, start_date: "2026-01-01", end_date: "2026-01-02") },
    first_seen_daily: -> { ClickhouseReadService.first_seen_daily(1, start_date: "2026-01-01", end_date: "2026-01-02") },
    campaign_metrics_daily: -> { ClickhouseReadService.campaign_metrics_daily(1, start_date: "2026-01-01", end_date: "2026-01-02") },
    event_filter_values: -> { ClickhouseReadService.event_filter_values(1) },
    link_event_type_counts: -> { ClickhouseReadService.link_event_type_counts(1, link_ids: [1], start_date: "2026-01-01", end_date: "2026-01-02") },
    billing_active_visitors: -> { ClickhouseReadService.billing_active_visitors([1], start_date: "2026-01-01", end_date: "2026-01-02") },
    project_version_daily_stats: -> { ClickhouseReadService.project_version_daily_stats(1, start_date: "2026-01-01", end_date: "2026-01-02") }
  }.freeze

  PRIMARY_STRICT_READS.each do |name, call|
    test "#{name} raises under primary and falls back without it" do
      down = ->(*) { raise ClickHouse::Client::DatabaseError, CH_OUTAGE }

      Clickhouse.stub(:with, down) { assert call.call.blank?, "#{name} must stay soft off primary" }

      Rails.application.config.clickhouse_primary = true
      Clickhouse.stub(:with, down) do
        assert_raises(Clickhouse::Unavailable, "#{name} must not resolve to a non-CH answer") { call.call }
      end
    end
  end

  private

  # test_helper pins primary off and restores all four flags after every test.
  def clear_own_read_flags
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = false
    Rails.application.config.clickhouse_attribution_read_enabled = false
    Rails.application.config.revenue_reads_from_ledger = false
  end
end
