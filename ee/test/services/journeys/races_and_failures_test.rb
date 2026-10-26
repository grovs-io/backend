require "test_helper"
require "sidekiq/testing"

class Journeys::RacesAndFailuresTest < ActiveSupport::TestCase
  include JourneyFixtures
  include InAppFixtures
  include ConstStubHelper
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    @ana = visitors(:ios_visitor)
    devices(:ios_device).update_columns(push_token: "tok-ios")
    @ana.update_columns(sdk_attributes: {})
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
    REDIS.with { |c| c.del(BatchEventProcessorJob::REDIS_KEY, Journeys::Watchlist.key(@project.id)) }
  end

  teardown do
    Sidekiq::Testing.disable!
    REDIS.with { |c| c.del(BatchEventProcessorJob::REDIS_KEY) }
  end

  def visitor(**attrs) = Visitor.create!({ project: @project, device: devices(:web_device) }.merge(attrs))

  # Each call to `with` takes the next answer: :real uses Redis, anything else raises as a lost connection does.
  class ScriptedRedis
    def initialize(real, *script)
      @real = real
      @script = script
    end

    def with(&block) = @script.shift == :real ? @real.with(&block) : raise(Redis::CannotConnectError, "down")
  end

  def redis(*script, &block) = with_const(Object, :REDIS, ScriptedRedis.new(REDIS, *script), &block)

  test "an until-event that lands while the timeout is being claimed keeps the person waiting for the did-it branch" do
    steps = map(step("w", "wait", minutes: 60, next: "p", until: { kind: "event", event: { name: "checkout" } }, timeout_next: "t"),
                step("p", "push"), step("t", "set_attribute", key: "journey_timed_out", value: "yes"))
    j = live_journey(@project, steps: steps)
    signal(@project, seen(@ana, "add_to_cart"))
    row = row_of(j, @ana)
    build = Journeys::Channels.method(:new)
    arrives = lambda do |*args|
      row.update_columns(until_hit: true)
      build.call(*args)
    end
    at = 2.hours.from_now
    travel_to(at) { Journeys::Channels.stub(:new, arrives) { Journeys::Stepper.new(j.reload).run } }
    row.reload
    assert_equal %w[active w], [row.state, row.step_id]
    assert row.until_hit, "the hit the claim missed is kept"
    assert_in_delta at, row.due_at, 1, "due again at once"
    assert_nil @ana.reload.sdk_attributes["journey_timed_out"]
    assert_equal 0, counts(j).fetch(%w[w timeout_next], 0)

    step_all(j, at: at + 1.second)
    assert PushDelivery.exists?(journey_person_id: row.id), "the next pass takes the did-it branch"
    assert_equal 1, counts(j)[%w[w next]]
    assert_nil @ana.reload.sdk_attributes["journey_timed_out"]
  end

  test "a merge that drops a row at an in-app step takes its message off that visitor's devices" do
    j = live_journey(@project, steps: map(step("i", "in_app")))
    key = j.membership_key("i")
    zoe = visitor(sdk_identifier: "zoe")
    signal(@project, seen(zoe, "add_to_cart"))
    anon = visitor
    travel(1.minute) { signal(@project, seen(anon, "add_to_cart")) }
    assert_equal [zoe.id, anon.id].sort, SegmentMembership.where(segment_key: key).pluck(:visitor_id).sort
    REDIS.with { |c| c.del("in_app:user:#{anon.id}") }

    anon.update!(sdk_identifier: "zoe")
    JourneyGateway.identified(anon)
    assert_equal [[person(zoe), zoe.id]], JourneyPerson.where(journey_id: j.id).pluck(:person_key, :visitor_id)
    assert_equal [zoe.id], SegmentMembership.where(segment_key: key).pluck(:visitor_id), "the older row wins and keeps its message"
    assert_not_equal InAppStamps::NEVER, InAppStamps.user(anon.id), "the dropped device is told to sync"
  end

  test "event data sent as JSON text is read; a list or broken JSON reads as no properties, and the batch goes on" do
    filters = [{ "field" => "value", "op" => "gt", "value" => 20 }]
    live_journey(@project, entry: ADD_TO_CART.merge("event" => { "name" => "add_to_cart", "filters" => filters }))
    row = ->(data) { { project_id: @project.id, device_id: @ana.device_id, event: Grovs::Events::CUSTOM, event_name: "add_to_cart", data: data, created_at: Time.current } }
    rows = [row.call('{"value":30,"secret":"x"}'), row.call("[1,2]"), row.call("{not json"), row.call(nil)]
    Journeys.observe(rows, { [@project.id, @ana.device_id] => @ana })
    assert_equal [{ "value" => 30 }, {}, {}, {}], JourneyEventJob.jobs.sole["args"][1].map { |r| r[4] }
  end

  test "with Redis down the watchlist answers nothing to watch, so no batch is queued or failed" do
    live_journey(@project)
    redis do
      assert_equal({}, Journeys::Watchlist.for([@project.id]))
      row = { project_id: @project.id, device_id: @ana.device_id, event: Grovs::Events::CUSTOM, event_name: "add_to_cart", data: {}, created_at: Time.current }
      assert_nothing_raised { Journeys.observe([row], { [@project.id, @ana.device_id] => @ana }) }
    end
    assert_empty JourneyEventJob.jobs
  end

  test "a list Redis could not store is still answered from Postgres, and is read again next time" do
    live_journey(@project)
    REDIS.with { |c| c.del(Journeys::Watchlist.key(@project.id)) }
    list = redis(:real) { Journeys::Watchlist.for([@project.id]) }
    assert_equal ["e:add_to_cart"], list[@project.id]["keys"]
    assert list[@project.id]["any"]
    assert_nil REDIS.with { |c| c.get(Journeys::Watchlist.key(@project.id)) }
  end
end
