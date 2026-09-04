require "test_helper"

class LogEventJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs

  setup do
    @job = LogEventJob.new
    @project = projects(:one)
    @device = devices(:ios_device)
    @link = links(:basic_link)
  end

  test "creates an event record in the database" do
    assert_difference "Event.count", 1 do
      @job.perform(Grovs::Events::OPEN, @project.id, @device.id, nil, @link.id, 500)
    end

    event = Event.last
    assert_equal Grovs::Events::OPEN, event.event
    assert_equal @device.id, event.device_id
    assert_equal @link.id, event.link_id
  end

  test "creates event without link when link_id is nil" do
    assert_difference "Event.count", 1 do
      @job.perform(Grovs::Events::OPEN, @project.id, @device.id, nil, nil, nil)
    end

    assert_nil Event.last.link_id
  end

  test "parses created_at ISO string and assigns to event" do
    ts = "2026-03-15T10:30:00Z"
    @job.perform(Grovs::Events::OPEN, @project.id, @device.id, nil, nil, nil, ts)

    event = Event.last
    assert_in_delta Time.parse(ts), event.created_at, 2
  end

  test "silently skips when project_id is invalid" do
    assert_no_difference "Event.count" do
      @job.perform(Grovs::Events::OPEN, 999999, @device.id, nil, nil, nil)
    end
  end

  test "silently skips when device_id is invalid" do
    assert_no_difference "Event.count" do
      @job.perform(Grovs::Events::OPEN, @project.id, 999999, nil, nil, nil)
    end
  end

  test "handles malformed created_at gracefully — event still created" do
    assert_difference "Event.count", 1 do
      @job.perform(Grovs::Events::OPEN, @project.id, @device.id, nil, nil, nil, "not-a-date")
    end
  end

  # --- enrichment fields ---

  test "enrichment fields are saved atomically with the event" do
    @job.perform(
      Grovs::Events::CUSTOM, @project.id, @device.id, nil, @link.id, nil, nil,
      "add_to_cart", "sess-abc", ["checkout", "promo"]
    )

    event = Event.order(id: :desc).first
    assert_equal Grovs::Events::CUSTOM, event.event
    assert_equal "add_to_cart", event.event_name
    assert_equal "sess-abc", event.session_id
    assert_equal ["checkout", "promo"], event.tags
  end

  test "enrichment fields default to empty for backward-compatible payloads" do
    @job.perform(Grovs::Events::OPEN, @project.id, @device.id, nil, nil, nil, nil)

    event = Event.order(id: :desc).first
    assert_equal "", event.event_name
    assert_equal "", event.session_id
    assert_equal [], event.tags
  end

  # --- VIEW dedup: 5-second window ---

  test "VIEW dedup: second VIEW within 5 seconds updates existing event instead of creating new one" do
    # First VIEW creates a new event
    @job.perform(Grovs::Events::VIEW, @project.id, @device.id, nil, @link.id, nil)
    first_count = Event.where(event: "view", device_id: @device.id).count

    # Second VIEW within 5 seconds should NOT create a new event
    @job.perform(Grovs::Events::VIEW, @project.id, @device.id, nil, @link.id, nil)
    second_count = Event.where(event: "view", device_id: @device.id).count

    assert_equal first_count, second_count, "Second VIEW within 5s should dedup (update existing, not create new)"
  end

  test "non-VIEW events are NOT deduped" do
    @job.perform(Grovs::Events::OPEN, @project.id, @device.id, nil, @link.id, nil)
    @job.perform(Grovs::Events::OPEN, @project.id, @device.id, nil, @link.id, nil)

    open_count = Event.where(event: "open", device_id: @device.id).count
    assert open_count >= 2, "OPEN events should NOT be deduped (got #{open_count})"
  end
end
