# frozen_string_literal: true

require "test_helper"

class BillingRollupFreshnessTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  setup do
    skip_unless_clickhouse!
    @original_read_enabled = Rails.application.config.clickhouse_read_enabled
    Rails.application.config.clickhouse_read_enabled = true
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read_enabled if defined?(@original_read_enabled)
  end

  test "billing rollup has rows through the latest billable event date" do
    insert_ch_events([
      billing_event(event_id: "fresh-1", event_type: Grovs::Events::OPEN, visitor_id: 101, device_id: 201, created_at: Time.utc(2026, 5, 20, 10)),
      billing_event(event_id: "fresh-2", event_type: Grovs::Events::VIEW, visitor_id: 102, device_id: 202, created_at: Time.utc(2026, 5, 21, 11)),
      billing_event(event_id: "fresh-custom", event_type: Grovs::Events::CUSTOM, visitor_id: 103, device_id: 203, created_at: Time.utc(2026, 5, 22, 12))
    ])
    # billing_active_visitors_daily is now rebuilt from canonical (was MV-fed).
    ClickhouseRollupRebuildService.rebuild_partition_range("202605", "202605", rollups: [:billing])

    row = Clickhouse.with do |conn|
      conn.select_one(<<~SQL)
        SELECT
          (
            SELECT max(toDate(created_at))
            FROM events FINAL
            WHERE project_id = 1
              AND visitor_id != 0
              AND event_type IN ('view','open','install','reinstall','time_spent','reactivation','app_open','user_referred')
          ) AS latest_event_date,
          (
            SELECT max(event_date)
            FROM billing_active_visitors_daily
            WHERE project_id = 1
          ) AS latest_rollup_date
      SQL
    end

    assert_equal "2026-05-21", row["latest_event_date"].to_s
    assert_equal row["latest_event_date"].to_s, row["latest_rollup_date"].to_s
  end

  private

  def billing_event(event_id:, event_type:, visitor_id:, device_id:, created_at:)
    {
      event_id: event_id,
      project_id: 1,
      event_type: event_type,
      visitor_id: visitor_id,
      device_id: device_id,
      created_at: created_at.strftime("%Y-%m-%d %H:%M:%S.%3N")
    }
  end
end
