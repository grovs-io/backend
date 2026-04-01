require "test_helper"

class AddEventJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs

  setup do
    @project = projects(:one)
    @device = devices(:ios_device)
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)
    @domain = domains(:one)
    @captured_payloads = []
  end

  test "resolves link from path and pushes correct payload to Redis" do
    with_captured_payloads do
      AddEventJob.new.perform(Grovs::Events::VIEW, @project.id, @device.id, nil, @link.path, nil, nil)
    end

    payload = @captured_payloads.last
    assert payload, "Should push event to Redis"
    assert_equal Grovs::Events::VIEW, payload["type"]
    assert_equal @project.id, payload["project_id"]
    assert_equal @device.id, payload["device_id"]
    assert_equal @link.id, payload["link_id"]
  end

  test "creates VisitorLastVisit for purchase attribution when link resolves" do
    VisitorLastVisit.where(project_id: @project.id, visitor_id: @visitor.id).delete_all

    AddEventJob.new.perform(Grovs::Events::VIEW, @project.id, @device.id, nil, @link.path, nil, nil)

    vlv = VisitorLastVisit.find_by(project_id: @project.id, visitor_id: @visitor.id)
    assert vlv, "VisitorLastVisit should be created for attribution"
    assert_equal @link.id, vlv.link_id
  end

  test "nil link_id and no VisitorLastVisit when nothing matches" do
    VisitorLastVisit.where(project_id: @project.id, visitor_id: @visitor.id).delete_all

    with_captured_payloads do
      AddEventJob.new.perform(Grovs::Events::VIEW, @project.id, @device.id, "https://nonexistent.example.com/x", nil, nil, nil)
    end

    payload = @captured_payloads.last
    assert payload
    assert_nil payload["link_id"]

    vlv = VisitorLastVisit.find_by(project_id: @project.id, visitor_id: @visitor.id)
    assert_nil vlv, "Should not create VisitorLastVisit without a link"
  end

  test "parsed ISO8601 timestamp appears in Redis payload" do
    ts = "2026-03-15T12:00:00Z"
    with_captured_payloads do
      AddEventJob.new.perform(Grovs::Events::VIEW, @project.id, @device.id, nil, nil, ts, nil)
    end

    payload = @captured_payloads.last
    assert payload
    assert_in_delta Time.parse(ts), Time.parse(payload["created_at"]), 1
  end

  test "invalid timestamp falls back to current time" do
    with_captured_payloads do
      AddEventJob.new.perform(Grovs::Events::VIEW, @project.id, @device.id, nil, nil, "not-a-time", nil)
    end

    payload = @captured_payloads.last
    assert payload
    assert_in_delta Time.current, Time.parse(payload["created_at"]), 5
  end

  test "engagement_time is passed through to Redis payload" do
    with_captured_payloads do
      AddEventJob.new.perform(Grovs::Events::TIME_SPENT, @project.id, @device.id, nil, nil, nil, 4200)
    end

    payload = @captured_payloads.last
    assert payload
    assert_equal 4200, payload["engagement_time"]
  end

  private

  def with_captured_payloads(&block)
    original_lpush = REDIS.method(:lpush)
    REDIS.stub(:lpush, lambda { |key, value|
      @captured_payloads << JSON.parse(value) if key == BatchEventProcessorJob::REDIS_KEY
      original_lpush.call(key, value)
    }, &block)
  end
end
