require "test_helper"
require "sidekiq/testing"

class Journeys::PurchaseTest < ActiveSupport::TestCase
  include JourneyFixtures
  include AuditTestHelper
  fixtures :instances, :projects, :visitors, :devices

  ANY = { "purchase" => true, "window_hours" => 168 }.freeze

  setup do
    @project = projects(:one)
    @ana = visitors(:ios_visitor)
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
  end

  teardown { Sidekiq::Testing.disable! }

  def purchase(visitor, product: "premium", at: Time.current, type: Grovs::Purchases::EVENT_BUY)
    PurchaseEvent.new(project: @project, event_type: type, product_id: product, visitor_id: visitor&.id, created_at: at)
  end

  # Hands purchases over as the purchase job does, then runs what was queued as JourneyEventJob would.
  def bought(*events)
    events.each { |e| Journeys.purchased(e) }
    JourneyEventJob.jobs.each { |job| signal(@project, *job["args"].last) }
    JourneyEventJob.clear
  end

  test "a purchase takes the person out, and a product goal waits for its product" do
    any = live_journey(@project, goals: [ANY], steps: map(step("w", "wait")))
    only = live_journey(@project, goals: [ANY.merge("products" => ["premium"])], steps: map(step("w", "wait")))
    signal(@project, seen(@ana, "add_to_cart"))
    travel(1.second) { bought(purchase(@ana, product: "coins")) }
    assert_equal %w[left goal], row_of(any, @ana).values_at(:state, :left_reason)
    assert_not_equal "left", row_of(only, @ana).state
    travel(2.seconds) { bought(purchase(@ana)) }
    assert_equal %w[left goal], row_of(only, @ana).values_at(:state, :left_reason)
  end

  test "a purchase from before entry does not count" do
    j = live_journey(@project, goals: [ANY], steps: map(step("w", "wait")))
    signal(@project, seen(@ana, "add_to_cart"))
    bought(purchase(@ana, at: 1.hour.ago))
    assert_not_equal "left", row_of(j, @ana).state
  end

  test "an app's own purchase events are no store purchase, and still meet event goals" do
    store = live_journey(@project, goals: [ANY], steps: map(step("w", "wait")))
    named = live_journey(@project, goals: [{ "event" => "purchase", "window_hours" => 168 }], steps: map(step("w", "wait")))
    signal(@project, seen(@ana, "add_to_cart"))
    travel(1.second) { signal(@project, seen(@ana, "purchase")) }
    assert_not_equal "left", row_of(store, @ana).state
    assert_equal "left", row_of(named, @ana).state

    row = { project_id: @project.id, device_id: @ana.device_id, event: Grovs::Events::CUSTOM, event_name: Journeys::PURCHASE, data: {},
            created_at: Time.current }
    JourneyGateway.observe([row], { [@project.id, @ana.device_id] => @ana })
    assert_empty JourneyEventJob.jobs
  end

  test "nothing is queued without a purchase goal, for a refund, or without a visitor" do
    live_journey(@project, goals: [{ "event" => "checkout", "window_hours" => 168 }], steps: map(step("w", "wait")))
    Journeys.purchased(purchase(@ana))
    assert_empty JourneyEventJob.jobs

    live_journey(@project, goals: [ANY], steps: map(step("w", "wait")))
    Journeys.purchased(purchase(@ana, type: Grovs::Purchases::EVENT_REFUND))
    Journeys.purchased(purchase(@ana, type: Grovs::Purchases::EVENT_REFUND_REVERSED))
    Journeys.purchased(purchase(nil))
    assert_empty JourneyEventJob.jobs
    Journeys.purchased(purchase(@ana))
    assert_equal 1, JourneyEventJob.jobs.size
  end

  test "a failure is logged, never raised" do
    live_journey(@project, goals: [ANY], steps: map(step("w", "wait")))
    Journeys::Watchlist.stub(:for, ->(_) { raise "boom" }) do
      assert_nothing_raised { Journeys.purchased(purchase(@ana)) }
    end
  end

  test "a processed store purchase takes the person out, through the real jobs" do
    entitle!(@project.instance)
    j = live_journey(@project, goals: [ANY.merge("products" => ["com.test.premium"])], steps: map(step("w", "wait")))
    signal(@project, seen(@ana, "add_to_cart"))
    travel(1.second) do
      event = PurchaseEvent.create!(event_type: Grovs::Purchases::EVENT_BUY, project: @project, device: devices(:ios_device),
                                    identifier: "com.test.app", price_cents: 999, currency: "USD", usd_price_cents: 999,
                                    date: Time.current, transaction_id: "flow-#{SecureRandom.hex(4)}", product_id: "com.test.premium",
                                    purchase_type: Grovs::Purchases::TYPE_ONE_TIME, webhook_validated: true, store: true, processed: false)
      ProcessPurchaseEventJob.new.perform(event.id)
    end
    assert_equal 6, JourneyEventJob.jobs.sole["args"].last.sole.size, "a purchase keeps the event-time rule: no receive time"
    JourneyEventJob.drain
    assert_equal %w[left goal], row_of(j, @ana).values_at(:state, :left_reason)
  end
end
