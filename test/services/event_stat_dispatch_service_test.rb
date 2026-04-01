require "test_helper"

class EventStatDispatchServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :events, :links, :domains, :redirect_configs

  setup do
    @project = projects(:one)
    @device = devices(:ios_device)
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)
  end

  test "skips already processed event" do
    event = events(:view_event)
    event.update_column(:processed, true)

    assert_no_difference ["LinkDailyStatistic.count", "VisitorDailyStatistic.count"] do
      EventStatDispatchService.call_normal_event(event)
    end
  end

  test "creates link stat for view event" do
    event = events(:view_event)
    # Use a fresh date so no fixture data contaminates the count
    event.update_columns(link_id: @link.id, processed: false, created_at: "2026-06-01 10:00:00")

    EventStatDispatchService.call_normal_event(event)

    stat = LinkDailyStatistic.find_by(
      project_id: @project.id, link_id: @link.id,
      event_date: Date.new(2026, 6, 1), platform: Grovs::Platforms::IOS
    )
    assert stat, "LinkDailyStatistic should exist"
    assert_equal 1, stat.views
    assert_equal 0, stat.opens
  end

  test "creates visitor stat for view event" do
    event = events(:view_event)
    event.update_columns(processed: false, created_at: "2026-06-01 10:00:00")

    EventStatDispatchService.call_normal_event(event)

    stat = VisitorDailyStatistic.find_by(
      project_id: @project.id, visitor_id: @visitor.id,
      event_date: Date.new(2026, 6, 1), platform: Grovs::Platforms::IOS
    )
    assert stat, "VisitorDailyStatistic should exist"
    assert_equal 1, stat.views
    assert_equal 0, stat.opens
  end

  test "uses engagement_time for time_spent" do
    fresh_date = Time.new(2026, 6, 2, 10, 0, 0)
    event = Event.create!(
      project: @project, device: @device, event: Grovs::Events::TIME_SPENT,
      platform: Grovs::Platforms::IOS, engagement_time: 5000, link: @link,
      created_at: fresh_date
    )

    EventStatDispatchService.call_normal_event(event)

    stat = LinkDailyStatistic.find_by(
      project_id: @project.id, link_id: @link.id,
      event_date: fresh_date.to_date, platform: Grovs::Platforms::IOS
    )
    assert stat, "LinkDailyStatistic should exist for time_spent"
    assert_equal 5000, stat.time_spent
    assert_equal 0, stat.views
  end

  test "returns nil for event type not in MAPPING" do
    event = events(:view_event)
    # Set an event type that exists as a constant but has no MAPPING entry
    event.update_columns(event: "custom_unmapped_type", processed: false)

    initial_link_stats = LinkDailyStatistic.count
    initial_visitor_stats = VisitorDailyStatistic.count

    result = EventStatDispatchService.call_normal_event(event)

    assert_nil result
    assert_equal initial_link_stats, LinkDailyStatistic.count, "Should not create link stats"
    assert_equal initial_visitor_stats, VisitorDailyStatistic.count, "Should not create visitor stats"
  end

  test "without link only creates visitor stat" do
    event = events(:view_event)
    event.update_columns(link_id: nil, processed: false)

    # No new link stat for nil link
    initial_link_count = LinkDailyStatistic.count
    EventStatDispatchService.call_normal_event(event)
    assert_equal initial_link_count, LinkDailyStatistic.count

    # But visitor stat is created
    stat = VisitorDailyStatistic.find_by(
      project_id: @project.id, visitor_id: @visitor.id,
      event_date: event.created_at.to_date, platform: Grovs::Platforms::IOS
    )
    assert stat
  end

  test "bulk returns both visitor and link updates" do
    event = events(:view_event)
    event.update_columns(link_id: @link.id, processed: false)
    event.reload

    result = EventStatDispatchService.call_normal_event_bulk(event)
    assert result[:visitor_updates]
    assert result[:link_updates]
    assert_equal @link.id, result[:link_updates][:link_id]
  end

  test "bulk returns nil link_updates without link" do
    event = events(:view_event)
    event.update_columns(link_id: nil, processed: false)
    event.reload

    result = EventStatDispatchService.call_normal_event_bulk(event)
    assert result[:visitor_updates]
    assert_nil result[:link_updates]
  end

  test "bulk returns nil when no visitor" do
    # Use a device with no visitor for this project
    orphan_device = Device.create!(user_agent: "Test", ip: "1.1.1.1", remote_ip: "2.2.2.2", platform: Grovs::Platforms::IOS)
    event = Event.create!(
      project: @project, device: orphan_device, event: Grovs::Events::VIEW,
      platform: Grovs::Platforms::IOS
    )

    result = EventStatDispatchService.call_normal_event_bulk(event)
    assert_nil result
  end

  test "bulk_process_updates dispatches to both services" do
    event = events(:view_event)
    event.update_columns(link_id: @link.id, processed: false)
    event.reload

    update = EventStatDispatchService.call_normal_event_bulk(event)
    assert update

    new_date = Date.new(2026, 6, 1)
    update[:visitor_updates][:stats][:event_date] = new_date
    update[:link_updates][:event_date] = new_date

    assert_difference ["VisitorDailyStatistic.count", "LinkDailyStatistic.count"], 1 do
      EventStatDispatchService.bulk_process_updates([update])
    end
  end

  test "bulk_process_updates with empty batch is noop" do
    assert_no_difference ["VisitorDailyStatistic.count", "LinkDailyStatistic.count"] do
      EventStatDispatchService.bulk_process_updates([])
    end
  end
end
