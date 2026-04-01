require "test_helper"

class EventMetricsQueryTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :domains, :links, :devices, :campaigns, :redirect_configs

  setup do
    @project = projects(:one)
    @link = links(:basic_link)
    @ios_device = devices(:ios_device)
    @android_device = devices(:android_device)
    @query = EventMetricsQuery.new(project: @project)

    # Clean fixture events to control exact counts
    Event.where(project: @project).delete_all

    # Day 1 events on basic_link
    @e1 = Event.create!(project: @project, device: @ios_device, link: @link,
                        event: "view", platform: "ios", engagement_time: 5000,
                        created_at: "2026-03-01 10:00:00")
    @e2 = Event.create!(project: @project, device: @ios_device, link: @link,
                        event: "view", platform: "ios", engagement_time: 3000,
                        created_at: "2026-03-01 11:00:00")
    @e3 = Event.create!(project: @project, device: @ios_device, link: @link,
                        event: "install", platform: "ios", engagement_time: 0,
                        created_at: "2026-03-01 12:00:00")
    # Day 2 events on basic_link
    @e4 = Event.create!(project: @project, device: @android_device, link: @link,
                        event: "view", platform: "android", engagement_time: 2000,
                        created_at: "2026-03-02 10:00:00")
  end

  # =========================================================================
  # metrics_for_link_ids
  # =========================================================================

  test "metrics_for_link_ids returns correct view and install counts" do
    result = @query.metrics_for_link_ids([@link.id], Date.new(2026, 3, 1), Date.new(2026, 3, 2))

    assert result.key?(@link.id), "Expected metrics for basic_link"
    metrics = result[@link.id]
    assert_equal 3, metrics[:view], "e1 + e2 + e4 = 3 views"
    assert_equal 1, metrics[:install], "e3 = 1 install"
    assert_equal 0, metrics[:open]
    assert_equal 0, metrics[:reinstall]
    assert_equal 0, metrics[:reactivation]
  end

  test "metrics_for_link_ids returns empty hash for nonexistent link" do
    result = @query.metrics_for_link_ids([999_999], Date.new(2026, 3, 1), Date.new(2026, 3, 2))
    assert_empty result
  end

  test "metrics_for_link_ids respects date range boundaries" do
    result = @query.metrics_for_link_ids([@link.id], Date.new(2026, 3, 1), Date.new(2026, 3, 1))
    metrics = result[@link.id]

    # Only day 1: e1, e2 (views) + e3 (install). e4 is on day 2.
    assert_equal 2, metrics[:view]
    assert_equal 1, metrics[:install]
  end

  test "metrics_for_link_ids computes avg_engagement_time per device correctly" do
    # Remove install events so only "view" events remain — no running average ambiguity.
    Event.where(project: @project, event: "install").delete_all

    # For "view" events: ios_device has 5000+3000=8000, android_device has 2000.
    # total_engagement_time=10000, device_count=2, avg_per_device=5000.0
    # Single event type means no running average — result is deterministic.
    result = @query.metrics_for_link_ids([@link.id], Date.new(2026, 3, 1), Date.new(2026, 3, 2))
    avg = result[@link.id][:avg_engagement_time]

    assert_equal 5000.0, avg
  end

  test "metrics_for_link_ids avg_engagement_time is exact when single event type" do
    # Remove install events so only "view" events remain - no running average ambiguity
    Event.where(project: @project, event: "install").delete_all

    result = @query.metrics_for_link_ids([@link.id], Date.new(2026, 3, 1), Date.new(2026, 3, 2))
    avg = result[@link.id][:avg_engagement_time]

    # 3 view events: ios_device total=5000+3000=8000, android_device total=2000
    # total_engagement=10000, device_count=2, avg_per_device = 10000/2 = 5000.0
    assert_equal 5000.0, avg
  end

  test "metrics_for_link_ids avg_engagement_time for single device" do
    # Keep only ios_device events and remove install events so avg is unambiguous
    Event.where(project: @project, device: @android_device).delete_all
    Event.where(project: @project, event: "install").delete_all

    result = @query.metrics_for_link_ids([@link.id], Date.new(2026, 3, 1), Date.new(2026, 3, 1))

    # "view" events only: ios_device total=5000+3000=8000, device_count=1, avg=8000.0
    # Single event type means no running average — result is deterministic.
    avg = result[@link.id][:avg_engagement_time]
    assert_equal 8000.0, avg
  end

  # =========================================================================
  # sorted_by_links
  # =========================================================================

  test "sorted_by_links descending returns link with most events first" do
    second_link = links(:second_link)
    Event.create!(project: @project, device: @android_device, link: second_link,
                  event: "view", platform: "android", engagement_time: 1000,
                  created_at: "2026-03-01 10:00:00")

    all_links = Link.where(id: [@link.id, second_link.id])
    result = @query.sorted_by_links(
      links: all_links, page: nil, event_type: "view",
      asc: false, start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 2)
    )

    assert_equal 2, result.size
    # basic_link has 3 views, second_link has 1 -- descending order
    assert_equal @link.id, result.first[:link].id
    assert_equal second_link.id, result.last[:link].id
  end

  test "sorted_by_links ascending returns link with fewest events first" do
    second_link = links(:second_link)
    Event.create!(project: @project, device: @android_device, link: second_link,
                  event: "view", platform: "android", engagement_time: 1000,
                  created_at: "2026-03-01 10:00:00")

    all_links = Link.where(id: [@link.id, second_link.id])
    result = @query.sorted_by_links(
      links: all_links, page: nil, event_type: "view",
      asc: true, start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 2)
    )

    assert_equal second_link.id, result.first[:link].id
    assert_equal @link.id, result.last[:link].id
  end

  test "sorted_by_links with pagination returns page metadata with correct keys" do
    all_links = Link.where(id: @link.id)
    result = @query.sorted_by_links(
      links: all_links, page: 1, event_type: "view",
      asc: false, start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 2)
    )

    assert result.key?(:result), "Expected :result key in paginated response"
    assert result.key?(:page), "Expected :page key"
    assert result.key?(:total_pages), "Expected :total_pages key"
    assert_equal 1, result[:page]
    assert_equal 1, result[:total_pages]
    assert_equal 1, result[:result].size
  end

  test "sorted_by_links includes correct metrics for each link" do
    all_links = Link.where(id: @link.id)
    result = @query.sorted_by_links(
      links: all_links, page: nil, event_type: "view",
      asc: false, start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 2)
    )

    entry = result.first
    assert_not_nil entry[:link]
    assert_not_nil entry[:metrics], "Expected :metrics for link entry"

    metrics = entry[:metrics]
    assert_equal 3, metrics[:view], "basic_link has 3 view events"
    assert_equal 1, metrics[:install], "basic_link has 1 install event"
    assert_equal 0, metrics[:open]
  end

  test "sorted_by_links returns nil metrics for links with no events" do
    # Create a link that has no events
    empty_link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "empty-link-#{SecureRandom.hex(4)}", active: true,
      sdk_generated: false, data: "[]", generated_from_platform: "ios"
    )

    all_links = Link.where(id: empty_link.id)
    result = @query.sorted_by_links(
      links: all_links, page: nil, event_type: "view",
      asc: false, start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 2)
    )

    assert_equal 1, result.size
    assert_nil result.first[:metrics], "Link with no events should have nil metrics"
  end

  # =========================================================================
  # sorted_by_campaigns
  # =========================================================================

  test "sorted_by_campaigns aggregates events per campaign with exact counts" do
    campaign = campaigns(:one)
    campaign_link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "campaign-link-#{SecureRandom.hex(4)}", campaign: campaign,
      active: true, sdk_generated: false, data: "[]",
      generated_from_platform: "ios"
    )
    Event.create!(project: @project, device: @ios_device, link: campaign_link,
                  event: "view", platform: "ios", engagement_time: 1000,
                  created_at: "2026-03-01 10:00:00")
    Event.create!(project: @project, device: @ios_device, link: campaign_link,
                  event: "view", platform: "ios", engagement_time: 2000,
                  created_at: "2026-03-01 11:00:00")
    Event.create!(project: @project, device: @ios_device, link: campaign_link,
                  event: "install", platform: "ios", engagement_time: 0,
                  created_at: "2026-03-01 12:00:00")

    campaigns_rel = Campaign.where(id: campaign.id)
    result = @query.sorted_by_campaigns(
      campaigns: campaigns_rel, page: 1, event_type: "view",
      asc: false, start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 2)
    )

    assert result.key?(:result)
    entry = result[:result].find { |r| r[:campaign]["id"] == campaign.id }
    assert_not_nil entry, "Expected entry for campaign"
    assert_equal 2, entry[:metrics][:view], "Campaign should have 2 view events"
    assert_equal 1, entry[:metrics][:install], "Campaign should have 1 install event"
    assert_includes entry[:links], campaign_link.id, "Should list campaign link IDs"
  end

  # =========================================================================
  # overview
  # =========================================================================

  test "overview groups events by day and returns exact counts per type" do
    events = Event.for_project(@project.id)
                  .where(created_at: Date.new(2026, 3, 1).beginning_of_day..Date.new(2026, 3, 2).end_of_day)

    result = @query.overview(events, "day", nil, nil, nil, nil)

    day1_key = result.keys.find { |k| k.include?("2026-03-01") }
    day2_key = result.keys.find { |k| k.include?("2026-03-02") }

    assert_not_nil day1_key
    assert_not_nil day2_key

    # Day 1: 2 views (e1, e2) + 1 install (e3) -- e4 is on day 2
    # Wait: e1 (view, day1), e2 (view, day1), e3 (install, day1), e4 (view, day2)
    assert_equal 2, result[day1_key][:view]
    assert_equal 1, result[day1_key][:install]
    assert_equal 0, result[day1_key][:open]

    # Day 2: 1 view (e4)
    assert_equal 1, result[day2_key][:view]
    assert_equal 0, result[day2_key][:install]
  end

  test "overview computes avg_engagement_time per event type per day" do
    # Remove install events so only "view" events remain — no running average ambiguity.
    Event.where(project: @project, event: "install").delete_all

    events = Event.for_project(@project.id)
                  .where(created_at: Date.new(2026, 3, 1).beginning_of_day..Date.new(2026, 3, 1).end_of_day)

    result = @query.overview(events, "day", nil, nil, nil, nil)
    day1_key = result.keys.find { |k| k.include?("2026-03-01") }

    # "view" on day 1: SQL AVG(5000, 3000) = 4000.0
    # overview running average: (initial 0.0 + 4000.0) / 2.0 = 2000.0
    avg = result[day1_key][:avg_engagement_time]
    assert_equal 2000.0, avg
  end

  test "overview filters by active link attribute" do
    # Create an event on inactive_link
    inactive_link = links(:inactive_link)
    Event.create!(project: @project, device: @ios_device, link: inactive_link,
                  event: "view", platform: "ios", engagement_time: 100,
                  created_at: "2026-03-01 15:00:00")

    events = Event.for_project(@project.id)
                  .where(created_at: Date.new(2026, 3, 1).beginning_of_day..Date.new(2026, 3, 1).end_of_day)

    # Filter active=true should exclude the inactive_link event
    active_result = @query.overview(events, "day", true, nil, nil, nil)
    day1_key = active_result.keys.find { |k| k.include?("2026-03-01") }

    # Only active link events: e1, e2 (views) + e3 (install)
    assert_equal 2, active_result[day1_key][:view]
    assert_equal 1, active_result[day1_key][:install]

    # Filter active=false should include only the inactive_link event
    inactive_result = @query.overview(events, "day", false, nil, nil, nil)
    inactive_day1 = inactive_result.keys.find { |k| k.include?("2026-03-01") }
    assert_equal 1, inactive_result[inactive_day1][:view]
    assert_equal 0, inactive_result[inactive_day1][:install]
  end

  test "overview filters by sdk_generated" do
    events = Event.for_project(@project.id)
                  .where(created_at: Date.new(2026, 3, 1).beginning_of_day..Date.new(2026, 3, 2).end_of_day)

    # basic_link has sdk_generated=false; filtering sdk_generated=true should exclude all events on it
    result = @query.overview(events, "day", nil, true, nil, nil)

    # No sdk_generated links have events, so result should be empty
    assert_empty result, "Expected no entries when filtering for sdk_generated=true (no sdk links have events)"
  end

  # =========================================================================
  # fill_gaps
  # =========================================================================

  test "fill_gaps inserts missing dates with zero defaults" do
    data = { "2026-03-01 00:00:00 UTC" => { "view" => 10 } }
    result = @query.fill_gaps(data, Date.new(2026, 3, 1), Date.new(2026, 3, 3), "day")

    assert result.key?("2026-03-02 00:00:00 UTC")
    assert_equal 0, result["2026-03-02 00:00:00 UTC"]["view"]
    assert_equal 0, result["2026-03-02 00:00:00 UTC"]["install"]
    assert_equal 0.0, result["2026-03-02 00:00:00 UTC"]["avg_engagement_time"]
    assert result.key?("2026-03-03 00:00:00 UTC")
  end

  test "fill_gaps inserts missing months for monthly period" do
    data = {}
    result = @query.fill_gaps(data, Date.new(2026, 1, 1), Date.new(2026, 3, 1), "month")

    assert result.key?("2026-01-01 00:00:00 UTC")
    assert result.key?("2026-02-01 00:00:00 UTC")
    assert result.key?("2026-03-01 00:00:00 UTC")
    assert_equal 3, result.size
  end

  test "fill_gaps preserves existing data" do
    data = { "2026-03-01 00:00:00 UTC" => { "view" => 42 } }
    result = @query.fill_gaps(data, Date.new(2026, 3, 1), Date.new(2026, 3, 2), "day")

    assert_equal 42, result["2026-03-01 00:00:00 UTC"]["view"]
  end

  test "fill_gaps returns keys in sorted chronological order" do
    data = {
      "2026-03-03 00:00:00 UTC" => { "view" => 3 },
      "2026-03-01 00:00:00 UTC" => { "view" => 1 }
    }
    result = @query.fill_gaps(data, Date.new(2026, 3, 1), Date.new(2026, 3, 3), "day")

    assert_equal result.keys, result.keys.sort
  end

  test "fill_gaps caps end_date at today and does not create future entries" do
    future = Date.today + 30
    data = {}
    result = @query.fill_gaps(data, Date.today - 1, future, "day")

    assert_not result.key?("#{future} 00:00:00 UTC"), "Should not have entries beyond today"
    # Should have entries from yesterday to today
    assert_equal 2, result.size
  end

  # =========================================================================
  # overview with campaign_ids filter
  # =========================================================================

  test "overview with campaign_ids filter returns only events from that campaign's links" do
    campaign = campaigns(:one)
    campaign_link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "campaign-filter-#{SecureRandom.hex(4)}", campaign: campaign,
      active: true, sdk_generated: false, data: "[]",
      generated_from_platform: "ios"
    )

    # Create events on the campaign link
    Event.create!(project: @project, device: @ios_device, link: campaign_link,
                  event: "view", platform: "ios", engagement_time: 1000,
                  created_at: "2026-03-01 10:00:00")
    Event.create!(project: @project, device: @ios_device, link: campaign_link,
                  event: "install", platform: "ios", engagement_time: 0,
                  created_at: "2026-03-01 11:00:00")

    # @link (basic_link) has no campaign -- its events should be excluded
    events = Event.for_project(@project.id)
                  .where(created_at: Date.new(2026, 3, 1).beginning_of_day..Date.new(2026, 3, 2).end_of_day)

    result = @query.overview(events, "day", nil, nil, nil, [campaign.id])
    day1_key = result.keys.find { |k| k.include?("2026-03-01") }

    assert_not_nil day1_key, "Expected a key for 2026-03-01"
    # Only campaign link events: 1 view, 1 install (not the 3 views + 1 install from basic_link)
    assert_equal 1, result[day1_key][:view]
    assert_equal 1, result[day1_key][:install]

    # Day 2 should not appear since e4 (basic_link, no campaign) is excluded
    day2_key = result.keys.find { |k| k.include?("2026-03-02") }
    assert_nil day2_key, "Expected no entries for day 2 (no campaign events on that day)"
  end

  # =========================================================================
  # overview with ads_platform filter
  # =========================================================================

  test "overview with ads_platform filter returns only events from links with that ads_platform" do
    ads_link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "ads-link-#{SecureRandom.hex(4)}", ads_platform: "meta",
      active: true, sdk_generated: false, data: "[]",
      generated_from_platform: "ios"
    )

    # Create events on the ads link
    Event.create!(project: @project, device: @ios_device, link: ads_link,
                  event: "view", platform: "ios", engagement_time: 500,
                  created_at: "2026-03-01 09:00:00")
    Event.create!(project: @project, device: @android_device, link: ads_link,
                  event: "install", platform: "android", engagement_time: 0,
                  created_at: "2026-03-01 09:30:00")

    events = Event.for_project(@project.id)
                  .where(created_at: Date.new(2026, 3, 1).beginning_of_day..Date.new(2026, 3, 2).end_of_day)

    result = @query.overview(events, "day", nil, nil, "meta", nil)
    day1_key = result.keys.find { |k| k.include?("2026-03-01") }

    assert_not_nil day1_key, "Expected a key for 2026-03-01"
    # Only ads_link events: 1 view, 1 install
    assert_equal 1, result[day1_key][:view]
    assert_equal 1, result[day1_key][:install]

    # Day 2 should not appear since basic_link (no ads_platform) events are excluded
    day2_key = result.keys.find { |k| k.include?("2026-03-02") }
    assert_nil day2_key, "Expected no entries for day 2 (no ads_platform events on that day)"
  end

  # =========================================================================
  # sorted_by_campaigns with empty campaign (no links)
  # =========================================================================

  test "sorted_by_campaigns with empty campaign having no links returns zero metrics" do
    campaign = campaigns(:one)
    # Ensure no links belong to this campaign
    Link.where(campaign_id: campaign.id).delete_all

    campaigns_rel = Campaign.where(id: campaign.id)
    result = @query.sorted_by_campaigns(
      campaigns: campaigns_rel, page: 1, event_type: "view",
      asc: false, start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 2)
    )

    assert result.key?(:result)
    assert_equal 1, result[:result].size

    entry = result[:result].first
    assert_equal campaign.id, entry[:campaign]["id"]
    assert_empty entry[:metrics], "Campaign with no links should have empty metrics hash"
    assert_empty entry[:links], "Campaign with no links should have empty links array"
  end
end
