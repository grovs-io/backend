# frozen_string_literal: true

require "test_helper"

# link_session_daily is the one rollup sourced from session_summary rather than events.
class ClickhouseLinkSessionRollupTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  PROJECT_ID = 8301
  LINK_ID = 5353
  OTHER_LINK_ID = 5454
  PARTITION = "202606"
  DAY = "2026-06-10"

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  teardown do
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  test "rebuild sums session duration and count per link" do
    seed_sessions([
      session("s1", LINK_ID, 30_000),
      session("s2", LINK_ID, 90_000),
      session("s3", OTHER_LINK_ID, 5_000)
    ])
    rebuild!

    assert_equal({ sessions: 2, duration: 120_000 }, rollup_for(LINK_ID))
    assert_equal({ sessions: 1, duration: 5_000 }, rollup_for(OTHER_LINK_ID))
  end

  test "bounced sessions are excluded from the average but still counted" do
    seed_sessions([
      session("s1", LINK_ID, 0),        # single-event bounce
      session("s2", LINK_ID, 40_000)
    ])
    rebuild!

    averages = ClickhouseReadService.link_session_avg_seconds(
      PROJECT_ID, link_ids: [LINK_ID], start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 30)
    )

    assert_equal 40.0, averages[LINK_ID], "40s over 1 engaged session, not 20s over 2"
    assert_equal({ sessions: 2, duration: 40_000 }, rollup_for(LINK_ID), "totals still stored")
  end

  test "a link with only bounces has no average rather than a zero" do
    seed_sessions([session("s1", LINK_ID, 0)])
    rebuild!

    averages = ClickhouseReadService.link_session_avg_seconds(
      PROJECT_ID, link_ids: [LINK_ID], start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 30)
    )

    assert_empty averages
  end

  test "sessions with no originating link are excluded" do
    seed_sessions([session("s1", 0, 60_000), session("s2", LINK_ID, 20_000)])
    rebuild!

    assert_equal 1, total_rows
    assert_equal({ sessions: 1, duration: 20_000 }, rollup_for(LINK_ID))
  end

  test "the reader divides totals, not per-day averages" do
    seed_sessions([
      session("s1", LINK_ID, 10_000),
      session("s2", LINK_ID, 30_000, date: "2026-06-11"),
      session("s3", LINK_ID, 30_000, date: "2026-06-11"),
      session("s4", LINK_ID, 30_000, date: "2026-06-11")
    ])
    rebuild!

    averages = ClickhouseReadService.link_session_avg_seconds(
      PROJECT_ID, link_ids: [LINK_ID], start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 30)
    )

    # 100s over 4 sessions = 25.0. Averaging the two days would give 20.0.
    assert_equal 25.0, averages[LINK_ID]
  end

  test "the rebuild is idempotent" do
    seed_sessions([session("s1", LINK_ID, 30_000)])
    rebuild!
    rebuild!

    assert_equal({ sessions: 1, duration: 30_000 }, rollup_for(LINK_ID))
  end

  private

  def rebuild!
    ClickhouseRollupRebuildService.rebuild_partition_range(
      PARTITION, PARTITION, rollups: %i[link_sessions]
    )
  end

  def session(session_id, link_id, duration_ms, date: DAY)
    {
      project_id: PROJECT_ID, session_id: session_id, visitor_id: 1, event_date: date,
      platform: "ios", country: "US", link_id: link_id, campaign_id: 0,
      screen_count: 0, event_count: 1, duration_ms: duration_ms,
      started_at: "#{date} 10:00:00.000", ended_at: "#{date} 10:00:30.000"
    }
  end

  def seed_sessions(rows)
    Clickhouse.with { |conn| conn.insert("session_summary", rows) }
  end

  def rollup_for(link_id)
    row = Clickhouse.with do |conn|
      conn.select_all(<<~SQL).first
        SELECT sum(sessions) AS sessions, sum(duration_ms_sum) AS duration
        FROM link_session_daily
        WHERE project_id = #{PROJECT_ID} AND link_id = #{link_id}
      SQL
    end
    { sessions: row["sessions"].to_i, duration: row["duration"].to_i }
  end

  def total_rows
    Clickhouse.with do |conn|
      conn.select_value("SELECT count() FROM link_session_daily WHERE project_id = #{PROJECT_ID}").to_i
    end
  end
end
