require "test_helper"

class ProcessNormalEventJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs, :events

  setup do
    @job = ProcessNormalEventJob.new
    @project = projects(:one)
    @device = devices(:ios_device)
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)
  end

  # --- Different event types generate correct stats ---

  test "VIEW event increments views on VisitorDailyStatistic" do
    event = Event.create!(project: @project, device: @device, event: "view", platform: "ios", link: @link)

    @job.perform(event.id)

    vds = VisitorDailyStatistic.find_by(visitor_id: @visitor.id, event_date: event.created_at.to_date, platform: "ios")
    assert_not_nil vds
    assert_equal 1, vds.views
  end

  test "OPEN event increments opens on VisitorDailyStatistic" do
    event = Event.create!(project: @project, device: @device, event: "open", platform: "ios", link: @link)

    @job.perform(event.id)

    vds = VisitorDailyStatistic.find_by(visitor_id: @visitor.id, event_date: event.created_at.to_date, platform: "ios")
    assert_not_nil vds
    assert_equal 1, vds.opens
  end

  test "INSTALL event increments installs on VisitorDailyStatistic" do
    event = Event.create!(project: @project, device: @device, event: "install", platform: "ios", link: @link)

    @job.perform(event.id)

    vds = VisitorDailyStatistic.find_by(visitor_id: @visitor.id, event_date: event.created_at.to_date, platform: "ios")
    assert_not_nil vds
    assert_equal 1, vds.installs
  end

  test "TIME_SPENT event uses engagement_time as value" do
    event = Event.create!(project: @project, device: @device, event: "time_spent", platform: "ios", engagement_time: 45000)

    @job.perform(event.id)

    vds = VisitorDailyStatistic.find_by(visitor_id: @visitor.id, event_date: event.created_at.to_date, platform: "ios")
    assert_not_nil vds
    assert_equal 45000, vds.time_spent, "Should use engagement_time as the value, not 1"
  end

  # --- Link daily statistics ---

  test "creates LinkDailyStatistic when event has link_id" do
    event = Event.create!(project: @project, device: @device, event: "view", platform: "ios", link: @link)

    @job.perform(event.id)

    lds = LinkDailyStatistic.find_by(link_id: @link.id, event_date: event.created_at.to_date, platform: "ios")
    assert_not_nil lds, "Should create LinkDailyStatistic"
    assert_equal 1, lds.views
  end

  test "does NOT create LinkDailyStatistic when event has no link" do
    event = Event.create!(project: @project, device: @device, event: "view", platform: "ios")
    lds_count_before = LinkDailyStatistic.count

    @job.perform(event.id)

    assert_equal lds_count_before, LinkDailyStatistic.count, "Should not create LDS without link"
  end

  # --- Idempotency ---

  test "already-processed event is not double-counted" do
    event = Event.create!(project: @project, device: @device, event: "view", platform: "ios", link: @link, processed: false)

    @job.perform(event.id)
    views_after_first = VisitorDailyStatistic.find_by(visitor_id: @visitor.id, event_date: event.created_at.to_date, platform: "ios")&.views || 0

    # Process again — should be idempotent because event.processed is now true
    @job.perform(event.id)
    views_after_second = VisitorDailyStatistic.find_by(visitor_id: @visitor.id, event_date: event.created_at.to_date, platform: "ios")&.views || 0

    assert_equal views_after_first, views_after_second, "Processing twice should not double-count"
  end

  test "marks event as processed" do
    event = Event.create!(project: @project, device: @device, event: "view", platform: "ios", processed: false)

    @job.perform(event.id)

    assert event.reload.processed?, "Event should be marked processed"
  end

  # --- Guard clause ---

  test "returns early for nonexistent event without side effects" do
    stat_count_before = VisitorDailyStatistic.count

    @job.perform(999999)

    assert_equal stat_count_before, VisitorDailyStatistic.count
  end
end
