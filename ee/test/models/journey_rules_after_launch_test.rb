require "test_helper"
require "sidekiq/testing"

class JourneyRulesAfterLaunchTest < ActiveSupport::TestCase
  include JourneyFixtures
  include InAppFixtures
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    clear_in_app_stamps(@project)
    Sidekiq::Testing.fake!
  end

  teardown { Sidekiq::Testing.disable! }

  def errors_for(steps)
    j = Journey.new(project: @project, name: "J", entry: ADD_TO_CART.deep_dup, first_step: steps.keys.first, steps: steps)
    j.valid?
    j.errors.full_messages.join(" | ")
  end

  test "a wait until something other than an event, an open or a click is refused, even in a draft" do
    message = errors_for(map(step("w", "wait", until: { kind: "viewed", step: "w" }, timeout_next: nil)))
    assert_includes message, "until kind must be event, opened or clicked"
    assert_includes errors_for(map(step("w", "wait", until: { step: "w" }, timeout_next: nil))), "until kind must be event, opened or clicked"
  end

  test "a split on a condition of an unknown kind is refused, so no journey sends everyone down no by mistake" do
    split = step("s", "split", mode: "condition", condition: { kind: "weather", values: ["sunny"] }, yes_next: nil, no_next: nil)
    assert_includes errors_for(map(split)), "condition kind must be event, segment, attribute or platform"
  end

  test "an edit to a launched in-app step reaches its campaign and sends devices to sync; the push beside it is left alone" do
    j = live_journey(@project, steps: map(step("p", "push", next: "i"), step("i", "in_app")))
    in_app = InAppCampaign.find_by_hashid(j.steps["i"]["campaign_id"])
    push = PushCampaign.find_by_hashid(j.steps["p"]["campaign_id"])
    pushed_at = push.updated_at
    stamp = InAppStamps.campaigns(@project.id)

    steps = j.steps.deep_dup
    steps["i"]["content"] = { "title" => "Back again", "message" => "20% off" }
    steps["i"]["caps"] = { "session" => 1 }
    travel(1.second) { j.update!(steps: steps) }

    in_app.reload
    assert_equal [{ "title" => "Back again", "message" => "20% off" }, { "session" => 1 }], [in_app.content.slice("title", "message"), in_app.caps]
    assert_equal pushed_at, push.reload.updated_at
    assert_not_equal stamp, InAppStamps.campaigns(@project.id)
  end

  test "an in-app edit its campaign refuses rolls the journey back with it" do
    j = live_journey(@project, steps: map(step("i", "in_app")))
    in_app = InAppCampaign.find_by_hashid(j.steps["i"]["campaign_id"])
    steps = j.steps.deep_dup
    steps["i"]["content"] = { "title" => "x" * 5_000, "message" => "m" }
    assert_raises(ActiveRecord::RecordInvalid) { j.update!(steps: steps) }
    assert_equal ["Hello", 1], [in_app.reload.content["title"], j.reload.revision]
  end
end
