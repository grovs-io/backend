# frozen_string_literal: true

require "test_helper"

class ClickhouseFirstSeenRollupTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  PROJECT_ID = 7601
  DEVICE = 6001

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables

    @original_ch_read = Rails.application.config.clickhouse_read_enabled
    Rails.application.config.clickhouse_read_enabled = true
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_ch_read if defined?(@original_ch_read)
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  test "second-platform debut is a first-time visitor there; later same-platform activity is not" do
    insert_ch_events([
      ev(100, "ios", "view", "2026-05-10 09:00:00.000"),
      ev(100, "ios", "view", "2026-06-03 09:00:00.000"), # later ios activity — no re-debut
      ev(100, "web", "view", "2026-06-05 09:00:00.000")  # web debut (R4-Issue1 case)
    ])
    rebuild!("202605", "202606")

    rows = read_range(Date.new(2026, 5, 1), Date.new(2026, 6, 30))
    assert_equal [
      ["2026-05-10", "ios", 1, 0],
      ["2026-06-05", "web", 1, 0]
    ], rows
  end

  test "installing on the first day makes a new_user; view-only and reinstall debuts do not" do
    insert_ch_events([
      ev(200, "ios", "install", "2026-06-02 10:00:00.000"),
      ev(201, "ios", "view", "2026-06-02 11:00:00.000"),
      ev(202, "ios", "view", "2026-06-02 12:00:00.000"),
      ev(202, "ios", "install", "2026-06-04 12:00:00.000"), # install AFTER debut day — not a new_user
      ev(203, "ios", "reinstall", "2026-06-02 13:00:00.000") # PG installs column ignores reinstalls
    ])
    rebuild!("202606")

    rows = read_range(Date.new(2026, 6, 1), Date.new(2026, 6, 30))
    assert_equal [["2026-06-02", "ios", 4, 1]], rows
  end

  test "non-mobile platforms normalize to web like PG platform_for_metrics" do
    insert_ch_events([
      ev(800, "desktop", "view", "2026-05-10 09:00:00.000"),
      ev(800, "mac", "view", "2026-06-01 09:00:00.000"), # same visitor, still 'web' — no re-debut
      ev(801, "windows", "install", "2026-06-03 09:00:00.000")
    ])
    rebuild!("202605", "202606")

    rows = read_range(Date.new(2026, 5, 1), Date.new(2026, 6, 30))
    assert_equal [
      ["2026-05-10", "web", 1, 0],
      ["2026-06-03", "web", 1, 1]
    ], rows

    web_only = ClickhouseReadService.first_seen_daily(
      PROJECT_ID, start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 6, 30), platform: "web"
    )
    assert_equal 2, web_only.size
  end

  test "a retried event (duplicate event_id) counts one first-time visitor" do
    row = ev(300, "ios", "view", "2026-06-07 08:00:00.000", event_id: "retry-1")
    insert_ch_events([row])
    insert_ch_events([row])
    rebuild!("202606")

    rows = read_range(Date.new(2026, 6, 1), Date.new(2026, 6, 30))
    assert_equal [["2026-06-07", "ios", 1, 0]], rows
  end

  test "a merged visitor folds under the survivor keeping the earliest first-seen" do
    insert_ch_events([
      ev(400, "ios", "view", "2026-05-08 09:00:00.000"), # merged visitor's earlier debut
      ev(500, "ios", "view", "2026-06-01 09:00:00.000")  # survivor's own later debut
    ])
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, 400, 500)
    rebuild!("202605", "202606")

    rows = read_range(Date.new(2026, 5, 1), Date.new(2026, 6, 30))
    assert_equal [["2026-05-08", "ios", 1, 0]], rows, "survivor debuts once, at the merged visitor's earlier date"
  end

  test "non-countable event types do not establish first-seen" do
    insert_ch_events([
      ev(600, "ios", "custom", "2026-06-01 09:00:00.000", event_name: "custom_ping"),
      ev(600, "ios", "view", "2026-06-09 09:00:00.000")
    ])
    rebuild!("202606")

    rows = read_range(Date.new(2026, 6, 1), Date.new(2026, 6, 30))
    assert_equal [["2026-06-09", "ios", 1, 0]], rows, "the custom event must not pull first-seen earlier"
  end

  test "a failed read returns nil, never an empty result that reads as zero" do
    Rails.application.config.clickhouse_read_enabled = false
    assert_nil ClickhouseReadService.first_seen_daily(
      PROJECT_ID, start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 30)
    )
  end

  test "platform filter scopes the read" do
    insert_ch_events([
      ev(700, "ios", "view", "2026-06-10 09:00:00.000"),
      ev(701, "web", "view", "2026-06-10 09:00:00.000")
    ])
    rebuild!("202606")

    rows = ClickhouseReadService.first_seen_daily(
      PROJECT_ID, start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 30), platform: "web"
    )
    assert_equal [["2026-06-10", "web", 1, 0]], normalize(rows)
  end

  private

  def ev(visitor_id, platform, event_type, created_at, event_id: nil, event_name: "")
    {
      project_id: PROJECT_ID, visitor_id: visitor_id, device_id: DEVICE,
      inviter_id: 0, platform: platform, created_at: created_at,
      event_id: event_id, event_type: event_type, event_name: event_name,
      link_id: 0, engagement_time: 0
    }.compact
  end

  def rebuild!(*partitions)
    partitions.each { |p| ClickhouseRollupRebuildService.rebuild_partition(:first_seen, p) }
  end

  def read_range(start_date, end_date)
    normalize(
      ClickhouseReadService.first_seen_daily(PROJECT_ID, start_date: start_date, end_date: end_date)
    )
  end

  def normalize(rows)
    rows.map do |r|
      [r["event_date"].to_s, r["platform"], r["first_time_visitors"].to_i, r["new_users"].to_i]
    end
  end
end
