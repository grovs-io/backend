require "test_helper"
require "sidekiq/testing"

class JourneyStepLoopTest < ActiveSupport::TestCase
  include JourneyFixtures
  include ConstStubHelper
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
    @journey = live_journey(@project, steps: map(step("w", "wait", minutes: 5)))
  end

  teardown do
    Sidekiq::Testing.disable!
    REDIS.with { |c| c.keys("journeys:step:*").each { |k| c.del(k) } }
  end

  def held_worker = JourneyStepJob.max_workers.times.map { |i| JourneyStepJob.worker_key(i) }.find { |k| REDIS.with { |c| c.get(k) } }

  # Hands back the given batch sizes in turn, and records what each pass saw of the leases.
  def stepper(sizes, seen, slot: 0)
    leases = -> { [JourneyStepJob.slot_key(@journey.id, slot), held_worker] }
    ttl = ->(key) { REDIS.with { |c| c.ttl(key) } }
    lambda do |_journey|
      Object.new.tap do |fake|
        fake.define_singleton_method(:run) do
          keys = leases.call
          seen << keys.map(&ttl)
          REDIS.with { |c| keys.each { |k| c.expire(k, 5) } }
          sizes.shift
        end
      end
    end
  end

  test "a full batch runs again at once, keeping both leases alive; a short one ends the loop with nothing queued" do
    seen = []
    Journeys::Stepper.stub(:new, stepper([Journeys::Stepper::BATCH, Journeys::Stepper::BATCH, 3], seen)) do
      JourneyStepJob.new.perform(@journey.id, 0)
    end
    assert_equal 3, seen.size
    seen.drop(1).each { |slot, worker| assert_operator [slot, worker].min, :>, 5, "each pass renews the leases to #{JourneyStepJob::SLOT_TTL}s" }
    assert_empty JourneyStepJob.jobs
    assert_nil REDIS.with { |c| c.get(JourneyStepJob.slot_key(@journey.id, 0)) }
    assert_nil held_worker, "the worker lease is given back"
  end

  test "a loop out of time after a full batch hands the same slot to a fresh job" do
    seen = []
    with_const(JourneyStepJob, :LOOP_SECONDS, 0) do
      Journeys::Stepper.stub(:new, stepper([Journeys::Stepper::BATCH, Journeys::Stepper::BATCH], seen, slot: 2)) do
        JourneyStepJob.new.perform(@journey.id, 2)
      end
    end
    assert_equal 1, seen.size, "it stops after the pass that ran out of time"
    assert_equal [[@journey.id, 2]], JourneyStepJob.jobs.map { |job| job["args"] }
    assert_nil REDIS.with { |c| c.get(JourneyStepJob.slot_key(@journey.id, 2)) }
  end

  test "a busy split ends the loop without queueing more" do
    seen = []
    Journeys::Stepper.stub(:new, stepper([:busy, Journeys::Stepper::BATCH], seen)) { JourneyStepJob.new.perform(@journey.id, 0) }
    assert_equal 1, seen.size, "busy must stop the loop after one pass"
    assert_empty JourneyStepJob.jobs
  end

  test "one journey failing in the tick never stops the others" do
    other = live_journey(@project, steps: map(step("w", "wait", minutes: 5)))
    [@journey, other].each do |j|
      JourneyPerson.create!(journey: j, person_key: "v:#{j.id}", visitor_id: visitors(:ios_visitor).id, step_id: "w", state: "active",
                            due_at: 1.minute.ago, entered_at: 10.minutes.ago)
    end
    enqueue = JourneyStepJob.method(:perform_async)
    failing = ->(id, slot) { id == @journey.id ? raise(Redis::CannotConnectError, "down") : enqueue.call(id, slot) }
    JourneyStepJob.stub(:perform_async, failing) { assert_nothing_raised { JourneyTickJob.new.perform } }
    assert_equal [[other.id, 0]], JourneyStepJob.jobs.map { |job| job["args"] }
  end
end
