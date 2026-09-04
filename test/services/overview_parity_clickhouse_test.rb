# frozen_string_literal: true

require "test_helper"

# Mechanical parity: same logical events seeded into BOTH stores (PG unset->NULL,
# CH unset->0), then overview == overview_ch. Covers the avg_engagement_time fixes.
# SCOPE: distinct event_ids only; the accepted redelivery/same-key CH<=PG collapse
# is by design and not covered here.
class OverviewParityClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :domains, :links, :devices, :redirect_configs, :campaigns

  DAY1 = "2026-05-01"
  DAY2 = "2026-05-02"

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
    @pid = @project.id
    @device = devices(:ios_device)
    @link = links(:basic_link)
    @query = EventMetricsQuery.new(project: @project)
    Event.where(project: @project).delete_all # same empty slate as truncated CH
  end

  test "overview == overview_ch on mixed engagement_time and multi-type days" do
    seed_both([
      [DAY1, "view", nil], [DAY1, "view", nil],
      [DAY1, "time_spent", 100], [DAY1, "time_spent", 50],
      [DAY1, "open", nil], [DAY1, "app_open", nil],
      [DAY2, "view", nil], [DAY2, "time_spent", 30], [DAY2, "install", nil]
    ])

    pg = @query.overview(Event.where(project: @project), "day", nil, nil, nil, nil)
    ch = @query.overview_ch([@pid], DAY1, DAY2)

    assert_equal pg, ch
    assert_equal pg["#{DAY1} 00:00:00 UTC"][:avg_engagement_time],
                 ch["#{DAY1} 00:00:00 UTC"][:avg_engagement_time]
  end

  # all-unset: PG AVG NULL->0.0, CH avgIf nan->0 (ifNotFinite)
  test "overview == overview_ch when no event has engagement_time" do
    seed_both([[DAY1, "view", nil], [DAY1, "open", nil], [DAY1, "install", nil]])

    pg = @query.overview(Event.where(project: @project), "day", nil, nil, nil, nil)
    ch = @query.overview_ch([@pid], DAY1, DAY2)

    assert_equal pg, ch
    assert_equal 0.0, ch["#{DAY1} 00:00:00 UTC"][:avg_engagement_time]
  end

  private

  # one source list -> PG rows (nil->NULL) + CH events (nil->0), each store's real form
  def seed_both(src)
    ch_rows = src.map do |day, type, et|
      Event.create!(project: @project, device: @device, link: @link, event: type,
                    created_at: "#{day} 12:00:00", engagement_time: et)
      { project_id: @pid, event_type: type, created_at: "#{day} 12:00:00.000",
        campaign_id: 0, sdk_generated: 0, engagement_time: et.to_i, platform: "ios" }
    end
    insert_ch_events(ch_rows)
  end
end
