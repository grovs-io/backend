require "test_helper"

class EventQueryServiceTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :domains, :links, :devices, :redirect_configs, :campaigns

  setup do
    @project = projects(:one)
    @link = links(:basic_link)
    @ios_device = devices(:ios_device)
    @android_device = devices(:android_device)
    @service = EventQueryService.new(project_ids: [@project.id])

    # Clean any fixture events so we control exact counts
    Event.where(project: @project).delete_all

    # --- Day 1 (March 1): 3 ios views, 1 android view, 1 ios install ---
    Event.create!(project: @project, device: @ios_device, link: @link,
                  event: "view", platform: "ios", app_version: "1.0", build: "100",
                  engagement_time: 5000, created_at: "2026-03-01 10:00:00")
    Event.create!(project: @project, device: @ios_device, link: @link,
                  event: "view", platform: "ios", app_version: "1.0", build: "100",
                  engagement_time: 3000, created_at: "2026-03-01 11:00:00")
    Event.create!(project: @project, device: @ios_device, link: @link,
                  event: "view", platform: "ios", app_version: "2.0", build: "200",
                  engagement_time: 1000, created_at: "2026-03-01 12:00:00")
    Event.create!(project: @project, device: @android_device, link: @link,
                  event: "view", platform: "android", app_version: "1.0", build: "100",
                  engagement_time: 2000, created_at: "2026-03-01 13:00:00")
    Event.create!(project: @project, device: @ios_device, link: @link,
                  event: "install", platform: "ios", app_version: "1.0", build: "100",
                  engagement_time: 0, created_at: "2026-03-01 14:00:00")

    # --- Day 2 (March 2): 1 android open ---
    Event.create!(project: @project, device: @android_device, link: @link,
                  event: "open", platform: "android", app_version: "2.0", build: "200",
                  engagement_time: 4000, created_at: "2026-03-02 10:00:00")
  end

  private

  # overview_metrics returns symbol keys for dates with events, string keys for gap-filled dates.
  # This helper fetches a metric value regardless of key type.
  def metric_value(counts, key)
    counts[key.to_sym] || counts[key.to_s] || 0
  end

  public

  # --- overview_metrics returns correct event counts ---

  test "overview_metrics returns exact event counts per date" do
    result = @service.overview_metrics(
      start_date: "2026-03-01",
      end_date: "2026-03-02"
    )

    day1_key = result.keys.find { |k| k.include?("2026-03-01") }
    day2_key = result.keys.find { |k| k.include?("2026-03-02") }

    assert_not_nil day1_key, "Expected a key for 2026-03-01"
    assert_not_nil day2_key, "Expected a key for 2026-03-02"

    # Day 1: 4 views (3 ios + 1 android), 1 install
    assert_equal 4, metric_value(result[day1_key], "view")
    assert_equal 1, metric_value(result[day1_key], "install")
    assert_equal 0, metric_value(result[day1_key], "open")

    # Day 2: 1 open, 0 views, 0 installs
    assert_equal 0, metric_value(result[day2_key], "view")
    assert_equal 1, metric_value(result[day2_key], "open")
    assert_equal 0, metric_value(result[day2_key], "install")
  end

  # --- gap filling ---

  test "overview_metrics gap fills missing dates with zeros" do
    # Use a fixed past date range to avoid future-date issues
    result = @service.overview_metrics(
      start_date: "2026-03-01",
      end_date: "2026-03-03"
    )

    # All dates are in the past, so all 3 should be present
    assert_equal 3, result.size

    # Day 3 has no events — should be gap-filled with zeros
    day3_key = result.keys.find { |k| k.include?("2026-03-03") }
    assert_not_nil day3_key, "Expected a key for 2026-03-03"
    assert_equal 0, metric_value(result[day3_key], "view")
    assert_equal 0, metric_value(result[day3_key], "install")
    assert_equal 0, metric_value(result[day3_key], "open")
  end

  # --- platform filter ---

  test "overview_metrics platform filter excludes events from other platforms" do
    ios_result = @service.overview_metrics(
      start_date: "2026-03-01",
      end_date: "2026-03-02",
      platforms: ["ios"]
    )

    day1_key = ios_result.keys.find { |k| k.include?("2026-03-01") }
    day2_key = ios_result.keys.find { |k| k.include?("2026-03-02") }

    # Day 1: only 3 ios views (the android view is excluded), 1 ios install
    assert_equal 3, metric_value(ios_result[day1_key], "view")
    assert_equal 1, metric_value(ios_result[day1_key], "install")

    # Day 2: the android open should be excluded, so all zeros (gap-filled)
    assert_equal 0, metric_value(ios_result[day2_key], "view")
    assert_equal 0, metric_value(ios_result[day2_key], "open")
  end

  test "overview_metrics android platform filter shows only android events" do
    android_result = @service.overview_metrics(
      start_date: "2026-03-01",
      end_date: "2026-03-02",
      platforms: ["android"]
    )

    day1_key = android_result.keys.find { |k| k.include?("2026-03-01") }
    day2_key = android_result.keys.find { |k| k.include?("2026-03-02") }

    # Day 1: 1 android view only, 0 installs (ios install excluded)
    assert_equal 1, metric_value(android_result[day1_key], "view")
    assert_equal 0, metric_value(android_result[day1_key], "install")

    # Day 2: 1 android open
    assert_equal 1, metric_value(android_result[day2_key], "open")
  end

  # --- app_version filter ---

  test "overview_metrics app_version filter returns only matching version events" do
    result_v1 = @service.overview_metrics(
      start_date: "2026-03-01",
      end_date: "2026-03-02",
      app_versions: ["1.0"]
    )

    day1_key = result_v1.keys.find { |k| k.include?("2026-03-01") }
    day2_key = result_v1.keys.find { |k| k.include?("2026-03-02") }

    # Day 1 version 1.0: 2 ios views + 1 android view = 3, 1 install
    assert_equal 3, metric_value(result_v1[day1_key], "view")
    assert_equal 1, metric_value(result_v1[day1_key], "install")

    # Day 2: the android open is version 2.0 so excluded (gap-filled)
    assert_equal 0, metric_value(result_v1[day2_key], "open")
  end

  test "overview_metrics app_version 2.0 filter returns only v2 events" do
    result_v2 = @service.overview_metrics(
      start_date: "2026-03-01",
      end_date: "2026-03-02",
      app_versions: ["2.0"]
    )

    day1_key = result_v2.keys.find { |k| k.include?("2026-03-01") }
    day2_key = result_v2.keys.find { |k| k.include?("2026-03-02") }

    # Day 1 version 2.0: 1 ios view only
    assert_equal 1, metric_value(result_v2[day1_key], "view")
    assert_equal 0, metric_value(result_v2[day1_key], "install")

    # Day 2 version 2.0: 1 android open
    assert_equal 1, metric_value(result_v2[day2_key], "open")
  end

  # --- build filter ---

  test "overview_metrics build filter returns only matching build events" do
    result = @service.overview_metrics(
      start_date: "2026-03-01",
      end_date: "2026-03-02",
      build_versions: ["100"]
    )

    day1_key = result.keys.find { |k| k.include?("2026-03-01") }
    day2_key = result.keys.find { |k| k.include?("2026-03-02") }

    # Build 100: 2 ios views + 1 android view = 3, 1 install (all on day 1)
    assert_equal 3, metric_value(result[day1_key], "view")
    assert_equal 1, metric_value(result[day1_key], "install")

    # Day 2 open is build 200 so excluded (gap-filled)
    assert_equal 0, metric_value(result[day2_key], "open")
  end

  # --- no matching events ---

  test "overview_metrics with no matching events returns gap-filled zeros" do
    service = EventQueryService.new(project_ids: [999_999])
    result = service.overview_metrics(
      start_date: "2026-03-01",
      end_date: "2026-03-02"
    )

    result.each_value do |counts|
      counts.each do |key, value|
        next if key.to_s == "avg_engagement_time"
        assert_equal 0, value, "Expected 0 for #{key}"
      end
    end
  end

  # --- default date range ---

  test "overview_metrics defaults to 30-day range when dates are nil" do
    result = @service.overview_metrics

    # Default range is today-30..today, so 31 entries (gap-filled)
    expected_days = (Date.today - 30..Date.today).count
    assert_equal expected_days, result.size
  end

  # --- combined filters ---

  test "overview_metrics filters by active and sdk_generated link attributes" do
    # basic_link is active=true, sdk_generated=false
    result = @service.overview_metrics(
      start_date: "2026-03-01",
      end_date: "2026-03-02",
      active: true,
      sdk_generated: false
    )

    day1_key = result.keys.find { |k| k.include?("2026-03-01") }
    # All our events use basic_link which is active=true, sdk_generated=false
    assert_equal 4, metric_value(result[day1_key], "view")
    assert_equal 1, metric_value(result[day1_key], "install")
  end

  test "overview_metrics active=false filter excludes events on active links" do
    # All our events are on basic_link (active=true), so filtering active=false yields gap-filled zeros
    result = @service.overview_metrics(
      start_date: "2026-03-01",
      end_date: "2026-03-02",
      active: false
    )

    day1_key = result.keys.find { |k| k.include?("2026-03-01") }
    assert_equal 0, metric_value(result[day1_key], "view")
    assert_equal 0, metric_value(result[day1_key], "install")
  end

  # --- multiple platforms filter ---

  test "overview_metrics with multiple platforms filter includes both" do
    result = @service.overview_metrics(
      start_date: "2026-03-01",
      end_date: "2026-03-02",
      platforms: ["ios", "android"]
    )

    day1_key = result.keys.find { |k| k.include?("2026-03-01") }
    # Should include all events: 3 ios views + 1 android view = 4
    assert_equal 4, metric_value(result[day1_key], "view")
  end

  # --- campaign_id filter ---

  test "overview_metrics campaign_id filter returns only events from that campaign's links" do
    campaign = campaigns(:one)
    campaign_link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "eqs-campaign-#{SecureRandom.hex(4)}", campaign: campaign,
      active: true, sdk_generated: false, data: "[]",
      generated_from_platform: "ios"
    )

    # Create events on the campaign link
    Event.create!(project: @project, device: @ios_device, link: campaign_link,
                  event: "view", platform: "ios", app_version: "1.0", build: "100",
                  engagement_time: 1000, created_at: "2026-03-01 15:00:00")
    Event.create!(project: @project, device: @ios_device, link: campaign_link,
                  event: "install", platform: "ios", app_version: "1.0", build: "100",
                  engagement_time: 0, created_at: "2026-03-01 16:00:00")

    result = @service.overview_metrics(
      start_date: "2026-03-01",
      end_date: "2026-03-02",
      campaign_id: campaign.id
    )

    day1_key = result.keys.find { |k| k.include?("2026-03-01") }
    day2_key = result.keys.find { |k| k.include?("2026-03-02") }

    assert_not_nil day1_key, "Expected a key for 2026-03-01"

    # Only campaign link events: 1 view, 1 install (not the 4 views + 1 install from basic_link)
    assert_equal 1, metric_value(result[day1_key], "view")
    assert_equal 1, metric_value(result[day1_key], "install")

    # Day 2: basic_link open excluded (no campaign), gap-filled zeros
    assert_equal 0, metric_value(result[day2_key], "view")
    assert_equal 0, metric_value(result[day2_key], "open")
  end

  # --- ads_platform filter ---

  test "overview_metrics ads_platform filter returns only events from links with that ads_platform" do
    ads_link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "eqs-ads-#{SecureRandom.hex(4)}", ads_platform: "meta",
      active: true, sdk_generated: false, data: "[]",
      generated_from_platform: "ios"
    )

    # Create events on the ads link
    Event.create!(project: @project, device: @ios_device, link: ads_link,
                  event: "view", platform: "ios", app_version: "1.0", build: "100",
                  engagement_time: 500, created_at: "2026-03-01 15:00:00")
    Event.create!(project: @project, device: @android_device, link: ads_link,
                  event: "install", platform: "android", app_version: "1.0", build: "100",
                  engagement_time: 0, created_at: "2026-03-01 16:00:00")

    result = @service.overview_metrics(
      start_date: "2026-03-01",
      end_date: "2026-03-02",
      ads_platform: "meta"
    )

    day1_key = result.keys.find { |k| k.include?("2026-03-01") }
    day2_key = result.keys.find { |k| k.include?("2026-03-02") }

    assert_not_nil day1_key, "Expected a key for 2026-03-01"

    # Only ads_link events: 1 view, 1 install
    assert_equal 1, metric_value(result[day1_key], "view")
    assert_equal 1, metric_value(result[day1_key], "install")

    # Day 2: basic_link open excluded (no ads_platform), gap-filled zeros
    assert_equal 0, metric_value(result[day2_key], "view")
    assert_equal 0, metric_value(result[day2_key], "open")
  end
end
