require "test_helper"

class EventTest < ActiveSupport::TestCase
  fixtures :events, :projects, :devices, :instances, :links, :domains, :redirect_configs

  # === validation ===

  test "valid event passes validation" do
    event = events(:view_event)
    assert event.valid?
  end

  test "invalid event type fails validation" do
    event = events(:view_event)
    event.event = "bogus_event"
    assert_not event.valid?
    assert event.errors[:event].any?
  end

  test "all ALL constants are valid" do
    Grovs::Events::ALL.each do |event_type|
      event = Event.new(
        project: projects(:one),
        device: devices(:ios_device),
        event: event_type
      )
      assert event.valid?, "Expected '#{event_type}' to be a valid event type"
    end
  end

  # === self.clamp_engagement_time ===

  test "clamp_engagement_time returns nil for nil" do
    assert_nil Event.clamp_engagement_time(nil)
  end

  test "clamp_engagement_time converts string to integer" do
    assert_equal 5000, Event.clamp_engagement_time("5000")
  end

  test "clamp_engagement_time converts float to integer" do
    assert_equal 3, Event.clamp_engagement_time(3.7)
  end

  test "clamp_engagement_time returns integer unchanged" do
    assert_equal 42, Event.clamp_engagement_time(42)
  end

  test "clamp_engagement_time returns 0 for zero" do
    assert_equal 0, Event.clamp_engagement_time(0)
  end

  test "clamp_engagement_time handles negative values" do
    assert_equal(-5, Event.clamp_engagement_time(-5))
  end

  # === platform_for_metrics ===

  test "platform_for_metrics returns ios for ios platform" do
    event = events(:view_event)
    event.platform = Grovs::Platforms::IOS
    assert_equal Grovs::Platforms::IOS, event.platform_for_metrics
  end

  test "platform_for_metrics returns android for android platform" do
    event = events(:android_view_event)
    event.platform = Grovs::Platforms::ANDROID
    assert_equal Grovs::Platforms::ANDROID, event.platform_for_metrics
  end

  test "platform_for_metrics returns web for desktop platform" do
    event = events(:web_app_open_event)
    event.platform = Grovs::Platforms::DESKTOP
    assert_equal Grovs::Platforms::WEB, event.platform_for_metrics
  end

  test "platform_for_metrics returns web for web platform" do
    event = events(:web_app_open_event)
    event.platform = Grovs::Platforms::WEB
    assert_equal Grovs::Platforms::WEB, event.platform_for_metrics
  end

  test "platform_for_metrics returns web for nil platform" do
    event = events(:web_app_open_event)
    event.platform = nil
    assert_equal Grovs::Platforms::WEB, event.platform_for_metrics
  end

  test "platform_for_metrics returns web for unknown platform" do
    event = events(:web_app_open_event)
    event.platform = "unknown"
    assert_equal Grovs::Platforms::WEB, event.platform_for_metrics
  end

  # === valid_for_platform_metrics? ===

  test "valid_for_platform_metrics? returns true for view event on any platform" do
    event = events(:view_event)
    event.event = Grovs::Events::VIEW
    event.platform = Grovs::Platforms::WEB
    assert event.valid_for_platform_metrics?
  end

  test "valid_for_platform_metrics? returns true for open event on web" do
    event = events(:web_app_open_event)
    event.event = Grovs::Events::OPEN
    event.platform = Grovs::Platforms::WEB
    assert event.valid_for_platform_metrics?
  end

  test "valid_for_platform_metrics? returns true for install on ios" do
    event = events(:install_event)
    event.event = Grovs::Events::INSTALL
    event.platform = Grovs::Platforms::IOS
    assert event.valid_for_platform_metrics?
  end

  test "valid_for_platform_metrics? returns true for install on android" do
    event = events(:reinstall_event)
    event.event = Grovs::Events::INSTALL
    event.platform = Grovs::Platforms::ANDROID
    assert event.valid_for_platform_metrics?
  end

  test "valid_for_platform_metrics? returns false for install on web" do
    event = events(:web_app_open_event)
    event.event = Grovs::Events::INSTALL
    event.platform = Grovs::Platforms::WEB
    assert_not event.valid_for_platform_metrics?
  end

  test "valid_for_platform_metrics? returns false for app_open on desktop" do
    event = events(:web_app_open_event)
    event.event = Grovs::Events::APP_OPEN
    event.platform = Grovs::Platforms::DESKTOP
    assert_not event.valid_for_platform_metrics?
  end

  test "valid_for_platform_metrics? returns false for reinstall on web" do
    event = events(:web_app_open_event)
    event.event = Grovs::Events::REINSTALL
    event.platform = Grovs::Platforms::WEB
    assert_not event.valid_for_platform_metrics?
  end

  test "valid_for_platform_metrics? returns false for reactivation on web" do
    event = events(:web_app_open_event)
    event.event = Grovs::Events::REACTIVATION
    event.platform = Grovs::Platforms::WEB
    assert_not event.valid_for_platform_metrics?
  end

  test "valid_for_platform_metrics? returns true for time_spent on any platform" do
    event = events(:web_app_open_event)
    event.event = Grovs::Events::TIME_SPENT
    event.platform = Grovs::Platforms::WEB
    assert event.valid_for_platform_metrics?
  end

  test "valid_for_platform_metrics? returns true for user_referred on any platform" do
    event = events(:web_app_open_event)
    event.event = Grovs::Events::USER_REFERRED
    event.platform = Grovs::Platforms::DESKTOP
    assert event.valid_for_platform_metrics?
  end

  # === APP_SPECIFIC_EVENTS ===

  test "APP_SPECIFIC_EVENTS contains exactly app_open install reinstall reactivation" do
    expected = [Grovs::Events::APP_OPEN, Grovs::Events::INSTALL, Grovs::Events::REINSTALL, Grovs::Events::REACTIVATION]
    assert_equal expected.sort, Event::APP_SPECIFIC_EVENTS.sort
  end

  # === valid_for_platform_metrics? (additional edge cases) ===

  test "valid_for_platform_metrics? returns false for app_open on web platform" do
    event = events(:web_app_open_event)
    event.event = Grovs::Events::APP_OPEN
    event.platform = Grovs::Platforms::WEB
    assert_not event.valid_for_platform_metrics?
  end

  test "valid_for_platform_metrics? returns true for time_spent on ios" do
    event = events(:view_event)
    event.event = Grovs::Events::TIME_SPENT
    event.platform = Grovs::Platforms::IOS
    assert event.valid_for_platform_metrics?
  end

  test "valid_for_platform_metrics? returns true for time_spent on android" do
    event = events(:android_view_event)
    event.event = Grovs::Events::TIME_SPENT
    event.platform = Grovs::Platforms::ANDROID
    assert event.valid_for_platform_metrics?
  end

  test "valid_for_platform_metrics? returns true for time_spent on desktop" do
    event = events(:web_app_open_event)
    event.event = Grovs::Events::TIME_SPENT
    event.platform = Grovs::Platforms::DESKTOP
    assert event.valid_for_platform_metrics?
  end

  # === events_metrics_for_link_ids ===

  test "events_metrics_for_link_ids returns metrics grouped by link_id" do
    project = projects(:one)
    link = links(:basic_link)

    # Create events associated with the link
    Event.create!(project: project, device: devices(:ios_device), link: link, event: Grovs::Events::VIEW,
                  platform: Grovs::Platforms::IOS, engagement_time: 1000, created_at: "2026-03-01 10:00:00")
    Event.create!(project: project, device: devices(:ios_device), link: link, event: Grovs::Events::VIEW,
                  platform: Grovs::Platforms::IOS, engagement_time: 2000, created_at: "2026-03-01 11:00:00")
    Event.create!(project: project, device: devices(:android_device), link: link, event: Grovs::Events::OPEN,
                  platform: Grovs::Platforms::ANDROID, engagement_time: 500, created_at: "2026-03-01 12:00:00")

    result = EventMetricsQuery.new(project: project).metrics_for_link_ids([link.id], Date.new(2026, 3, 1), Date.new(2026, 3, 1))

    assert result.key?(link.id), "Expected metrics for link_id #{link.id}"
    assert_equal 2, result[link.id][:view]
    assert_equal 1, result[link.id][:open]
    assert_equal 0, result[link.id][:install]
  end

  test "events_metrics_for_link_ids returns empty hash for empty link_ids" do
    project = projects(:one)
    result = EventMetricsQuery.new(project: project).metrics_for_link_ids([], Date.new(2026, 3, 1), Date.new(2026, 3, 31))

    assert_equal({}, result)
  end

  test "events_metrics_for_link_ids returns empty hash when date range has no events" do
    project = projects(:one)
    link = links(:basic_link)

    Event.create!(project: project, device: devices(:ios_device), link: link, event: Grovs::Events::VIEW,
                  platform: Grovs::Platforms::IOS, engagement_time: 1000, created_at: "2026-03-01 10:00:00")

    # Query a date range with no events
    result = EventMetricsQuery.new(project: project).metrics_for_link_ids([link.id], Date.new(2025, 1, 1), Date.new(2025, 1, 31))

    assert_equal({}, result)
  end

  test "events_metrics_for_link_ids returns metrics for multiple links" do
    project = projects(:one)
    link_a = links(:basic_link)
    link_b = links(:inactive_link)

    Event.create!(project: project, device: devices(:ios_device), link: link_a, event: Grovs::Events::VIEW,
                  platform: Grovs::Platforms::IOS, engagement_time: 1000, created_at: "2026-03-01 10:00:00")
    Event.create!(project: project, device: devices(:android_device), link: link_b, event: Grovs::Events::INSTALL,
                  platform: Grovs::Platforms::ANDROID, engagement_time: 0, created_at: "2026-03-01 11:00:00")

    result = EventMetricsQuery.new(project: project).metrics_for_link_ids([link_a.id, link_b.id], Date.new(2026, 3, 1), Date.new(2026, 3, 1))

    assert result.key?(link_a.id)
    assert result.key?(link_b.id)
    assert_equal 1, result[link_a.id][:view]
    assert_equal 1, result[link_b.id][:install]
  end

  # === metrics_for_events ===

  test "metrics_for_events computes event counts and device counts with engagement time" do
    project = projects(:one)
    link = links(:basic_link)

    Event.create!(project: project, device: devices(:ios_device), link: link, event: Grovs::Events::VIEW,
                  platform: Grovs::Platforms::IOS, engagement_time: 4000, created_at: "2026-03-01 10:00:00")
    Event.create!(project: project, device: devices(:android_device), link: link, event: Grovs::Events::VIEW,
                  platform: Grovs::Platforms::ANDROID, engagement_time: 6000, created_at: "2026-03-01 11:00:00")
    Event.create!(project: project, device: devices(:ios_device), link: link, event: Grovs::Events::OPEN,
                  platform: Grovs::Platforms::IOS, engagement_time: 1000, created_at: "2026-03-01 12:00:00")

    events_rel = Event.where(link_id: link.id, created_at: Date.new(2026, 3, 1).beginning_of_day..Date.new(2026, 3, 1).end_of_day)
    result = EventMetricsQuery.new(project: nil).send(:aggregate,events_rel)

    assert result.key?(link.id)
    assert_equal 2, result[link.id][:view]
    assert_equal 1, result[link.id][:open]
    # avg_engagement_time should be a float
    assert_instance_of Float, result[link.id][:avg_engagement_time]
    assert result[link.id][:avg_engagement_time] > 0
  end

  test "metrics_for_events returns empty hash for empty relation" do
    events_rel = Event.none
    result = EventMetricsQuery.new(project: nil).send(:aggregate,events_rel)

    assert_equal({}, result)
  end

  test "metrics_for_events initializes default zero values for all event types" do
    project = projects(:one)
    link = links(:basic_link)

    # Create only a single VIEW event
    Event.create!(project: project, device: devices(:ios_device), link: link, event: Grovs::Events::VIEW,
                  platform: Grovs::Platforms::IOS, engagement_time: 500, created_at: "2026-03-01 10:00:00")

    events_rel = Event.where(link_id: link.id, created_at: Date.new(2026, 3, 1).beginning_of_day..Date.new(2026, 3, 1).end_of_day)
    result = EventMetricsQuery.new(project: nil).send(:aggregate,events_rel)

    assert_equal 1, result[link.id][:view]
    assert_equal 0, result[link.id][:open]
    assert_equal 0, result[link.id][:install]
    assert_equal 0, result[link.id][:reinstall]
    assert_equal 0, result[link.id][:reactivation]
  end

  # === fill_missing_metrics_entries ===

  test "fill_missing_metrics_entries fills missing days in a day period" do
    start_date = Date.new(2026, 3, 1)
    end_date = Date.new(2026, 3, 5)

    # Only provide data for day 1 and day 3
    result_hash = {
      "2026-03-01 00:00:00 UTC" => { "view" => 10, "open" => 5 },
      "2026-03-03 00:00:00 UTC" => { "view" => 3, "open" => 1 }
    }

    filled = EventMetricsQuery.new(project: nil).fill_gaps(result_hash, start_date, end_date, "day")

    # All 5 days should be present
    (start_date..end_date).each do |date|
      key = "#{date} 00:00:00 UTC"
      assert filled.key?(key), "Expected key #{key} to be present"
    end

    # Original data should be preserved
    assert_equal 10, filled["2026-03-01 00:00:00 UTC"]["view"]
    assert_equal 3, filled["2026-03-03 00:00:00 UTC"]["view"]

    # Missing days should have default zeros
    assert_equal 0, filled["2026-03-02 00:00:00 UTC"]["view"]
    assert_equal 0, filled["2026-03-04 00:00:00 UTC"]["view"]
    assert_equal 0, filled["2026-03-05 00:00:00 UTC"]["view"]
    assert_equal 0.0, filled["2026-03-02 00:00:00 UTC"]["avg_engagement_time"]
  end

  test "fill_missing_metrics_entries fills missing months in a month period" do
    start_date = Date.new(2026, 1, 1)
    end_date = Date.new(2026, 3, 1)

    result_hash = {
      "2026-01-01 00:00:00 UTC" => { "view" => 100 }
    }

    filled = EventMetricsQuery.new(project: nil).fill_gaps(result_hash, start_date, end_date, "month")

    assert filled.key?("2026-01-01 00:00:00 UTC"), "Expected January entry"
    assert filled.key?("2026-02-01 00:00:00 UTC"), "Expected February entry"
    assert filled.key?("2026-03-01 00:00:00 UTC"), "Expected March entry"

    # Original data preserved
    assert_equal 100, filled["2026-01-01 00:00:00 UTC"]["view"]

    # Filled months have defaults
    assert_equal 0, filled["2026-02-01 00:00:00 UTC"]["view"]
    assert_equal 0, filled["2026-03-01 00:00:00 UTC"]["view"]
  end

  test "fill_missing_metrics_entries returns entries sorted by date" do
    start_date = Date.new(2026, 3, 1)
    end_date = Date.new(2026, 3, 3)

    # Insert in reverse order
    result_hash = {
      "2026-03-03 00:00:00 UTC" => { "view" => 1 },
      "2026-03-01 00:00:00 UTC" => { "view" => 3 }
    }

    filled = EventMetricsQuery.new(project: nil).fill_gaps(result_hash, start_date, end_date, "day")
    keys = filled.keys

    assert_equal "2026-03-01 00:00:00 UTC", keys[0]
    assert_equal "2026-03-02 00:00:00 UTC", keys[1]
    assert_equal "2026-03-03 00:00:00 UTC", keys[2]
  end

  test "fill_missing_metrics_entries with no gaps returns same entries" do
    start_date = Date.new(2026, 3, 1)
    end_date = Date.new(2026, 3, 3)

    result_hash = {
      "2026-03-01 00:00:00 UTC" => { "view" => 10 },
      "2026-03-02 00:00:00 UTC" => { "view" => 20 },
      "2026-03-03 00:00:00 UTC" => { "view" => 30 }
    }

    filled = EventMetricsQuery.new(project: nil).fill_gaps(result_hash, start_date, end_date, "day")

    # Original data should all be preserved, no defaults injected
    assert_equal 10, filled["2026-03-01 00:00:00 UTC"]["view"]
    assert_equal 20, filled["2026-03-02 00:00:00 UTC"]["view"]
    assert_equal 30, filled["2026-03-03 00:00:00 UTC"]["view"]
    assert_equal 3, filled.size
  end

  test "fill_missing_metrics_entries clamps end_date to today" do
    start_date = Date.new(2026, 3, 15)
    end_date = Date.new(2099, 12, 31)  # far in the future

    result_hash = {}

    filled = EventMetricsQuery.new(project: nil).fill_gaps(result_hash, start_date, end_date, "day")

    # Should not contain dates beyond today
    today = Date.today
    filled.each_key do |key|
      date_str = key.split(" ").first
      assert Date.parse(date_str) <= today, "Expected date #{date_str} to not exceed today (#{today})"
    end
  end

  # === serialization ===

  test "serializer excludes project_id link_id and device_id" do
    event = events(:view_event)
    json = EventSerializer.serialize(event)
    assert_nil json["project_id"]
    assert_nil json["link_id"]
    assert_nil json["device_id"]
  end
end
