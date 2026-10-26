require "test_helper"
require "sidekiq/testing"

class Journeys::EngineTest < ActiveSupport::TestCase
  include JourneyFixtures
  include InAppFixtures
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    @ana = visitors(:ios_visitor)
    @bo = visitors(:android_visitor)
    devices(:ios_device).update_columns(push_token: "tok-ios")
    @ana.update_columns(sdk_attributes: { "plan" => "premium" })
    @bo.update_columns(sdk_attributes: { "plan" => "free" })
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
    REDIS.with { |c| c.del(BatchEventProcessorJob::REDIS_KEY) }
  end

  teardown do
    Sidekiq::Testing.disable!
    REDIS.with { |c| c.del(BatchEventProcessorJob::REDIS_KEY) }
  end

  def server_events = REDIS.with { |c| c.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1) }.map { |raw| JSON.parse(raw) }
  def visitor(**attrs) = Visitor.create!({ project: @project, device: devices(:web_device) }.merge(attrs))

  def wait_then_push(**wait)
    map(step("w", "wait", minutes: 60, next: "p", **wait), step("p", "push"), step("t", "set_attribute", key: "journey_timed_out", value: "yes"))
  end

  test "an event enters people through its filters, runs the first send at once, and never twice at the same time" do
    filters = [{ "field" => "value", "op" => "gt", "value" => 20 }]
    j = live_journey(@project, entry: ADD_TO_CART.merge("event" => { "name" => "add_to_cart", "filters" => filters }))
    signal(@project, seen(@ana, "add_to_cart", value: 30), seen(@bo, "add_to_cart", value: 10), seen(@ana, "add_to_cart", value: 50))

    row = row_of(j, @ana)
    assert_equal ["left", "finished"], [row.state, row.left_reason], "the push step ran at once and the path ended"
    assert_nil row_of(j, @bo)
    delivery = PushDelivery.find_by(journey_person_id: row.id)
    assert_equal ["pending", @ana.id], [delivery.status, delivery.visitor_id]
    assert_in_delta Time.current, delivery.due_at, 5
    assert_equal({ ["", "entered"] => 1, %w[s1 reached] => 1, %w[s1 next] => 1, ["", "finished"] => 1 }, counts(j))
    assert_equal ["journey_entered"], server_events.map { |e| e["event_name"] }
    assert_equal [PushDelivery.last.push_campaign_id], PushCampaignDeliverJob.jobs.map { |job| job["args"].first }.uniq
  end

  test "an entry event older than an hour is ignored" do
    j = live_journey(@project)
    signal(@project, seen(@ana, "add_to_cart", at: 2.hours.ago))
    assert_nil row_of(j, @ana)
  end

  test "re-entry: once, after exit, after days" do
    once = live_journey(@project)
    exit = live_journey(@project, re_entry: { "mode" => "after_exit", "days" => nil })
    days = live_journey(@project, re_entry: { "mode" => "after_days", "days" => 3 })
    signal(@project, seen(@ana, "add_to_cart"))
    first = [once, days].map { |j| row_of(j, @ana).entered_at }
    assert_equal "left", row_of(exit, @ana).state

    travel(1.day) { signal(@project, seen(@ana, "add_to_cart")) }
    assert_equal first, [row_of(once, @ana).entered_at, row_of(days, @ana).entered_at]
    assert_equal 2, counts(exit)[["", "entered"]]

    travel(4.days) { signal(@project, seen(@ana, "add_to_cart")) }
    assert_equal first[0], row_of(once, @ana).entered_at
    assert_operator row_of(days, @ana).entered_at, :>, first[1]
    assert_equal 1, JourneyPerson.where(journey_id: days.id).count
  end

  test "a person inside is never let in again, whatever the re-entry rule" do
    j = live_journey(@project, re_entry: { "mode" => "after_exit", "days" => nil }, steps: map(step("w", "wait")))
    signal(@project, seen(@ana, "add_to_cart"))
    entered = row_of(j, @ana).entered_at
    travel(1.minute) { signal(@project, seen(@ana, "add_to_cart")) }
    assert_equal [entered, "active", "w"], row_of(j, @ana).values_at(:entered_at, :state, :step_id)
  end

  test "an audience segment admits only its members" do
    segment = Segment.create!(project: @project, name: "Buyers", definition: SEGMENT_DEFINITION)
    j = live_journey(@project, entry: ADD_TO_CART.merge("audience_segment_id" => segment.hashid))
    SegmentMembership.create!(visitor_id: @bo.id, segment_key: j.segment_keys[segment.hashid]["key"], project_id: @project.id, confirmed_at: Time.current)
    signal(@project, seen(@ana, "add_to_cart"), seen(@bo, "add_to_cart"))
    assert_nil row_of(j, @ana)
    assert row_of(j, @bo)
  end

  test "the journey's control group and the project's hold people back and record them" do
    j = live_journey(@project, control_group: 50)
    people = Array.new(30) { visitor }
    InAppSetting.create!(project: @project, control_group: 10)
    signal(@project, *people.map { |v| seen(v, "add_to_cart") })

    held_project = people.select { |v| Experiments::Bucket.of(@project.hashid, v.id) < 10 }
    held_journey = (people - held_project).select { |v| Experiments::Bucket.of(j.hashid, v.id) < 50 }
    rows = JourneyPerson.where(journey_id: j.id)
    assert_equal (held_project + held_journey).map(&:id).sort, rows.where(left_reason: "held").pluck(:visitor_id).sort
    assert PushDelivery.where(journey_person_id: rows.where(left_reason: "held").select(:id)).none?
    held = server_events.select { |e| e["event_name"] == "journey_held" }
    assert_equal held_project.size, held.count { |e| e["data"]["scope"] == "project" }
    assert_equal held_journey.size, held.count { |e| e["data"]["scope"] == "campaign" }
    assert(held.all? { |e| e["data"]["campaign_id"] == j.hashid })
  end

  test "a segment entry takes the newcomers the membership refresh found" do
    segment = Segment.create!(project: @project, name: "New", definition: SEGMENT_DEFINITION)
    j = live_journey(@project, entry: { "type" => "segment", "event" => nil, "segment_id" => segment.hashid, "audience_segment_id" => nil })
    key = j.segment_keys["entry"]["key"]
    assert_equal [[nil, j.id]], InAppMembershipRefreshJob.jobs.map { |job| job["args"] }
    manifest = Segments::Results::Manifest.new(result_id: "a" * 32, project_id: @project.id, definition_hash: segment.definition_hash,
                                               list_generation: nil, persons: 2, devices: 2, incomplete: false)
    Segments::Results.stub(:for, manifest) do
      Segments::Runner.stub(:read, [{ "id" => @ana.id }, { "id" => @bo.id }]) { InAppMembershipRefreshJob.new.perform(nil, j.id) }
    end
    assert_equal [@ana.id, @bo.id].sort, SegmentMembership.where(segment_key: key).pluck(:visitor_id).sort
    assert_equal %w[active active], [row_of(j, @ana), row_of(j, @bo)].map(&:state)
    assert_includes JourneyStepJob.jobs.map { |job| job["args"] }, [j.id]
    step_all(j)
    assert_equal 2, PushDelivery.where(journey_person_id: JourneyPerson.where(journey_id: j.id).select(:id)).count
  end

  test "a wait with an until-event: the event takes the did-it branch, the timer the other" do
    j = live_journey(@project, steps: wait_then_push(until: { kind: "event", event: { name: "checkout", filters: [{ field: "total", op: "gt", value: 5 }] } },
                                                     timeout_next: "t"))
    signal(@project, seen(@ana, "add_to_cart"), seen(@bo, "add_to_cart"))
    assert_equal ["w", "e:checkout"], row_of(j, @ana).values_at(:step_id, :until_event)

    travel(1.minute) { signal(@project, seen(@ana, "checkout", total: 2), seen(@bo, "checkout", total: 9)) }
    assert row_of(j, @bo).until_hit
    assert_not row_of(j, @ana).until_hit, "the filter did not pass"
    assert_includes JourneyStepJob.jobs.map { |job| job["args"] }, [j.id]
    step_all(j, at: 2.minutes.from_now)
    assert PushDelivery.exists?(journey_person_id: row_of(j, @bo).id)
    assert_equal "w", row_of(j, @ana).step_id

    step_all(j, at: 2.hours.from_now)
    assert_equal "yes", @ana.reload.sdk_attributes["journey_timed_out"]
    assert_nil @bo.reload.sdk_attributes["journey_timed_out"]
    assert_equal({ "next" => 1, "timeout_next" => 1 }, counts(j).select { |(s, _), _| s == "w" }.except(%w[w reached]).transform_keys(&:last))
  end

  test "an event before the person entered never ends their wait" do
    j = live_journey(@project, steps: wait_then_push(until: { kind: "event", event: { name: "checkout" } }, timeout_next: "t"))
    signal(@project, seen(@ana, "add_to_cart"))
    signal(@project, seen(@ana, "checkout", at: 1.minute.ago))
    assert_not row_of(j, @ana).until_hit
  end

  test "until opened waits for a push_open of the step's own campaign; until clicked for the in-app one" do
    steps = map(step("p", "push", next: "w"), step("w", "wait", until: { kind: "opened", step: "p" }, next: "i", timeout_next: nil),
                step("i", "in_app", next: "c"), step("c", "wait", until: { kind: "clicked", step: "i" }, next: "done", timeout_next: nil),
                step("done", "set_attribute", key: "journey_clicked", value: "1"))
    j = live_journey(@project, steps: steps)
    push = j.steps["p"]["campaign_id"]
    signal(@project, seen(@ana, "add_to_cart"))
    assert_equal "o:#{push}", row_of(j, @ana).until_event

    signal(@project, seen(@ana, "push_open", campaign_id: "other"))
    assert_not row_of(j, @ana).until_hit
    signal(@project, seen(@ana, "push_open", campaign_id: push))
    step_all(j, at: 1.minute.from_now)
    assert_equal ["i", "v:#{j.steps['i']['campaign_id']}"], row_of(j, @ana).values_at(:step_id, :until_event)

    signal(@project, seen(@ana, "in_app_viewed", campaign_id: j.steps["i"]["campaign_id"]))
    step_all(j, at: 2.minutes.from_now)
    assert_equal "c", row_of(j, @ana).step_id
    signal(@project, seen(@ana, "in_app_clicked", campaign_id: j.steps["i"]["campaign_id"]))
    step_all(j, at: 3.minutes.from_now)
    assert_equal "1", @ana.reload.sdk_attributes["journey_clicked"]
  end

  test "an in-app step shows the message until it is viewed, or until it expires" do
    j = live_journey(@project, steps: map(step("i", "in_app", valid_days: 2)))
    key = j.membership_key("i")
    signal(@project, seen(@ana, "add_to_cart"), seen(@bo, "add_to_cart"))
    assert_equal [@ana.id, @bo.id].sort, SegmentMembership.where(segment_key: key).pluck(:visitor_id).sort
    campaign = InAppCampaign.find_by_hashid(j.steps["i"]["campaign_id"])
    assert_equal [campaign.hashid], InAppSync.call(project: @project, visitor: @ana, held: nil)["campaigns"].pluck("id")

    signal(@project, seen(@ana, "in_app_viewed", campaign_id: campaign.hashid))
    step_all(j, at: 1.minute.from_now)
    assert_equal [@bo.id], SegmentMembership.where(segment_key: key).pluck(:visitor_id)
    assert_equal "finished", row_of(j, @ana).left_reason

    step_all(j, at: 3.days.from_now)
    assert_empty SegmentMembership.where(segment_key: key)
    assert_equal "finished", row_of(j, @bo).left_reason
  end

  test "splits by segment, attribute and platform, and by percent the same way every time" do
    segment = Segment.create!(project: @project, name: "VIP", definition: SEGMENT_DEFINITION)
    mark = ->(id, value) { step(id, "set_attribute", key: "journey_path", value: value) }
    by = lambda do |condition|
      map(step("s", "split", mode: "condition", condition: condition, yes_next: "y", no_next: "n"), mark.call("y", "yes"), mark.call("n", "no"))
    end
    run = lambda do |steps, &prepare|
      j = live_journey(@project, steps: steps)
      prepare&.call(j)
      signal(@project, seen(@ana, "add_to_cart"), seen(@bo, "add_to_cart"))
      [@ana, @bo].map { |v| v.reload.sdk_attributes["journey_path"] }
    end

    assert_equal %w[no yes], run.call(by.call({ kind: "segment", segment_id: segment.hashid })) { |j|
      SegmentMembership.create!(visitor_id: @bo.id, segment_key: j.segment_keys[segment.hashid]["key"], project_id: @project.id, confirmed_at: Time.current)
    }
    assert_equal %w[yes no], run.call(by.call({ kind: "attribute", key: "plan", op: "eq", value: "Premium" }))
    assert_equal %w[no yes], run.call(by.call({ kind: "platform", values: ["android"] }))

    paths = map(step("s", "split", mode: "percent", paths: [{ percent: 50, next: "a" }, { percent: 50, next: "b" }]), mark.call("a", "a"), mark.call("b", "b"))
    j = live_journey(@project, steps: paths)
    expected = [@ana, @bo].map { |v| Experiments::Bucket.of("#{j.hashid}:s", v.id) < 50 ? "a" : "b" }
    signal(@project, seen(@ana, "add_to_cart"), seen(@bo, "add_to_cart"))
    assert_equal expected, [@ana, @bo].map { |v| v.reload.sdk_attributes["journey_path"] }
  end

  test "a percent split records the path each person took; a condition split records nothing" do
    paths = [{ percent: 30, next: "w" }, { percent: 30, next: "w" }, { percent: 40, next: "w" }]
    j = live_journey(@project, steps: map(step("s", "split", mode: "percent", paths: paths), step("w", "wait")))
    signal(@project, seen(@ana, "add_to_cart"), seen(@bo, "add_to_cart"))
    taken = Journeys::Forks.new(j).decide(j.steps["s"], [@ana.id, @bo.id])
    recorded = server_events.select { |e| e["event_name"] == "journey_path" }
    assert_equal [[@ana.device_id, { "campaign_id" => j.hashid, "step_id" => "s", "path" => taken[@ana.id] }],
                  [@bo.device_id, { "campaign_id" => j.hashid, "step_id" => "s", "path" => taken[@bo.id] }]].sort_by(&:first),
                 recorded.map { |e| [e["device_id"], e["data"]] }.sort_by(&:first)

    REDIS.with { |c| c.del(BatchEventProcessorJob::REDIS_KEY) }
    live_journey(@project, steps: map(step("s", "split", mode: "condition", condition: { kind: "platform", values: ["ios"] }, yes_next: "w", no_next: "w"),
                                      step("w", "wait")))
    signal(@project, seen(@ana, "add_to_cart"), seen(@bo, "add_to_cart"))
    assert_empty server_events.select { |e| e["event_name"] == "journey_path" }
  end

  test "a failed path record never undoes the move" do
    j = live_journey(@project, steps: map(step("s", "split", mode: "percent", paths: [{ percent: 50, next: "w" }, { percent: 50, next: "w" }]),
                                          step("w", "wait")))
    Experiments::Held.stub(:push, ->(_, name, *, **) { raise Redis::CannotConnectError if name == Journeys::Entry::PATH }) do
      assert_nothing_raised { signal(@project, seen(@ana, "add_to_cart")) }
    end
    assert_equal "w", row_of(j, @ana).step_id
  end

  test "a person whose goal arrived during the claim records no path" do
    j = live_journey(@project, goals: [{ "event" => "checkout", "window_hours" => 168 }],
                               steps: map(step("w", "wait", minutes: 5, next: "s"),
                                          step("s", "split", mode: "percent", paths: [{ percent: 50, next: nil }, { percent: 50, next: nil }])))
    signal(@project, seen(@ana, "add_to_cart"), seen(@bo, "add_to_cart"))
    row_of(j, @ana).update_columns(goal_hit: true)
    REDIS.with { |c| c.del(BatchEventProcessorJob::REDIS_KEY) }
    step_all(j, at: 10.minutes.from_now)
    assert_equal "goal", row_of(j, @ana).left_reason
    assert_equal [@bo.device_id], server_events.select { |e| e["event_name"] == "journey_path" }.map { |e| e["device_id"] }
  end

  test "a push with quiet hours waits for 09:00 on the device's clock" do
    j = live_journey(@project, steps: map(step("p", "push", quiet_hours: true)))
    night = Time.utc(2026, 10, 1, 4, 0) # 00:00 in New York
    travel_to(night) { signal(@project, seen(@ana, "add_to_cart")) }
    delivery = PushDelivery.find_by(journey_person_id: row_of(j, @ana).id)
    assert_equal Time.utc(2026, 10, 1, 13, 0), delivery.due_at
    assert_equal "pending", delivery.status
    assert_equal "no_channel", begin
      travel_to(night) { signal(@project, seen(@bo, "add_to_cart")) }
      PushDelivery.find_by(journey_person_id: row_of(j, @bo).id).status
    end
    campaign = PushCampaign.find(delivery.push_campaign_id)
    assert_equal [2, 1], [campaign.targeted, campaign.no_channel]
  end

  test "paths join, and a long run of instant steps stops at 20 until the next pass" do
    chain = (1..25).map { |i| step("a#{i}", "set_attribute", key: "journey_n", value: i.to_s, next: i < 25 ? "a#{i + 1}" : nil) }
    j = live_journey(@project, steps: map(*chain))
    signal(@project, seen(@ana, "add_to_cart"))
    row = row_of(j, @ana)
    assert_equal ["active", "a21"], [row.state, row.step_id]
    assert_equal "20", @ana.reload.sdk_attributes["journey_n"]
    step_all(j)
    assert_equal ["left", "25"], [row_of(j, @ana).state, @ana.reload.sdk_attributes["journey_n"]]

    joined = map(step("s", "split", mode: "percent", paths: [{ percent: 50, next: "x" }, { percent: 50, next: "y" }]),
                 step("x", "set_attribute", key: "journey_x", value: "1", next: "end"), step("y", "set_attribute", key: "journey_y", value: "1", next: "end"),
                 step("end", "set_attribute", key: "journey_end", value: "1"))
    j2 = live_journey(@project, steps: joined)
    signal(@project, seen(@ana, "add_to_cart"), seen(@bo, "add_to_cart"))
    assert_equal %w[1 1], [@ana, @bo].map { |v| v.reload.sdk_attributes["journey_end"] }
    assert_equal 2, counts(j2)[%w[end reached]]
  end

  test "a pass that starts mid-chain and hits the cap leaves the person due, never stranded" do
    chain = (1..45).map { |i| step("a#{i}", "set_attribute", key: "journey_n", value: i.to_s, next: i < 45 ? "a#{i + 1}" : nil) }
    j = live_journey(@project, steps: map(*chain))
    signal(@project, seen(@ana, "add_to_cart"))
    assert_equal "a21", row_of(j, @ana).step_id
    step_all(j)
    row = row_of(j, @ana)
    assert_equal ["active", "a41"], [row.state, row.step_id]
    assert_not_nil row.due_at
    step_all(j, at: 2.seconds.from_now)
    assert_equal ["left", "45"], [row_of(j, @ana).state, @ana.reload.sdk_attributes["journey_n"]]
  end

  test "a split reads an attribute set earlier in the same pass, and the last of several writes stays" do
    steps = map(step("a", "set_attribute", key: "journey_tier", value: "A", next: "b"),
                step("b", "set_attribute", key: "journey_tier", value: "B", next: "c"),
                step("c", "set_attribute", key: "journey_tier", value: "A", next: "s"),
                step("s", "split", mode: "condition", condition: { kind: "attribute", key: "journey_tier", op: "eq", value: "A" },
                                   yes_next: "y", no_next: nil),
                step("y", "set_attribute", key: "journey_seen_a", value: "1"))
    live_journey(@project, steps: steps)
    signal(@project, seen(@ana, "add_to_cart"))
    assert_equal %w[A 1], @ana.reload.sdk_attributes.values_at("journey_tier", "journey_seen_a")
  end

  test "set attribute writes the journey_ key on every device of an identified person" do
    phone = visitor(sdk_identifier: @ana.sdk_identifier)
    live_journey(@project, steps: map(step("a", "set_attribute", key: "journey_onboarded", value: "true")))
    signal(@project, seen(@ana, "add_to_cart"))
    assert_equal %w[true true], [@ana, phone].map { |v| v.reload.sdk_attributes["journey_onboarded"] }
    assert_equal "premium", @ana.sdk_attributes["plan"], "the app's own attributes stay"
  end

  test "a goal takes the person out from any step, and from a claimed row once the claim is over" do
    j = live_journey(@project, goals: [{ "event" => "checkout", "window_hours" => 168 }],
                               steps: map(step("i", "in_app", next: "w"), step("w", "wait", minutes: 60)))
    signal(@project, seen(@ana, "add_to_cart"), seen(@bo, "add_to_cart"))
    travel(1.second) { signal(@project, seen(@ana, "checkout")) }
    assert_equal ["left", "goal"], row_of(j, @ana).values_at(:state, :left_reason)
    assert_not SegmentMembership.exists?(segment_key: j.membership_key("i"), visitor_id: @ana.id)

    stepper = Journeys::Stepper.new(j.reload, now: 8.days.from_now)
    rows = stepper.send(:claim, [row_of(j, @bo).id])
    travel(1.second) { signal(@project, seen(@bo, "checkout")) }
    assert_equal ["claimed", true], row_of(j, @bo).values_at(:state, :goal_hit)
    stepper.send(:commit, stepper.send(:walk, rows))
    assert_equal ["left", "goal"], row_of(j, @bo).values_at(:state, :left_reason)
    assert_not SegmentMembership.exists?(segment_key: j.membership_key("i"), visitor_id: @bo.id)
    assert_equal 2, counts(j)[["", "goal"]]
  end

  test "a failure in the middle of a batch rolls back its channel writes and moves" do
    j = live_journey(@project, steps: map(step("w", "wait", minutes: 5, next: "i"), step("i", "in_app")))
    signal(@project, seen(@ana, "add_to_cart"))
    Journeys::Tally.stub(:add, ->(*, **) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_raises(ActiveRecord::StatementInvalid) { step_all(j, at: 10.minutes.from_now) }
    end
    assert_equal ["active", "w"], row_of(j, @ana).values_at(:state, :step_id)
    assert_empty SegmentMembership.where(segment_key: j.membership_key("i"))
    step_all(j, at: 10.minutes.from_now)
    assert_equal "i", row_of(j, @ana).step_id
    assert_equal 1, SegmentMembership.where(segment_key: j.membership_key("i")).count
  end

  test "a paused journey moves nobody and lets nobody in; an ended one lets people finish" do
    j = live_journey(@project, steps: map(step("w", "wait", minutes: 5, next: "a"), step("a", "set_attribute", key: "journey_done", value: "1")))
    signal(@project, seen(@ana, "add_to_cart"))
    assert j.pause!
    signal(@project, seen(@bo, "add_to_cart"))
    assert_nil row_of(j, @bo)
    assert_equal 0, step_all(j, at: 10.minutes.from_now)
    assert_equal "w", row_of(j, @ana).step_id

    assert j.resume!
    assert j.end!
    signal(@project, seen(@bo, "add_to_cart"))
    assert_nil row_of(j, @bo)
    step_all(j, at: 10.minutes.from_now)
    assert_equal "1", @ana.reload.sdk_attributes["journey_done"]
  end

  test "the tick closes an ended journey once nobody is left, and releases stale claims" do
    j = live_journey(@project, steps: map(step("i", "in_app", next: "w"), step("w", "wait", minutes: 5)))
    signal(@project, seen(@ana, "add_to_cart"))
    row_of(j, @ana).update_columns(state: "claimed", claimed_at: 11.minutes.ago, due_at: 1.minute.ago)
    JourneyTickJob.new.perform
    assert_equal "active", row_of(j, @ana).state
    assert_equal [[j.id, 0]], JourneyStepJob.jobs.map { |job| job["args"] }.select { |a| a.size == 2 }.uniq

    j.end!
    JourneyTickJob.new.perform
    assert_nil j.reload.finished_at
    row_of(j, @ana).update_columns(state: "left")
    JourneyTickJob.new.perform
    assert_not_nil j.reload.finished_at
    assert_equal "ended", InAppCampaign.find_by_hashid(j.steps["i"]["campaign_id"]).status
  end

  test "identify moves an anonymous row to the person, and the older row wins" do
    anon = visitor
    j = live_journey(@project, steps: map(step("w", "wait")))
    signal(@project, seen(anon, "add_to_cart"))
    anon.update!(sdk_identifier: "zoe")
    JourneyGateway.identified(anon)
    assert_equal ["i:zoe"], JourneyPerson.where(journey_id: j.id).pluck(:person_key)

    other = visitor
    travel(1.minute) { signal(@project, seen(other, "add_to_cart")) }
    other.update!(sdk_identifier: "zoe")
    JourneyGateway.identified(other)
    assert_equal ["i:zoe"], JourneyPerson.where(journey_id: j.id).pluck(:person_key)
    assert_equal anon.id, JourneyPerson.find_by(journey_id: j.id).visitor_id, "the older row stayed"
  end

  test "a merge keeps the row of whoever is still inside over a leaver's row, whichever is older" do
    j = live_journey(@project, re_entry: { "mode" => "after_exit", "days" => nil }, steps: map(step("w", "wait")))
    left = visitor
    signal(@project, seen(left, "add_to_cart"))
    row_of(j, left).update_columns(state: "left", left_at: Time.current, left_reason: "finished", due_at: nil)
    inside = visitor
    travel(1.minute) { signal(@project, seen(inside, "add_to_cart")) }
    JourneyGateway.merge(from: inside, to: left)
    assert_equal [[person(left), "active", left.id]], JourneyPerson.where(journey_id: j.id).pluck(:person_key, :state, :visitor_id)

    k = live_journey(@project, re_entry: { "mode" => "after_exit", "days" => nil }, steps: map(step("w", "wait")))
    older = visitor
    signal(@project, seen(older, "add_to_cart"))
    newer = visitor
    travel(1.minute) { signal(@project, seen(newer, "add_to_cart")) }
    row_of(k, newer).update_columns(state: "left", left_at: Time.current, left_reason: "finished", due_at: nil)
    JourneyGateway.merge(from: older, to: newer)
    assert_equal [[person(newer), "active", newer.id]], JourneyPerson.where(journey_id: k.id).pluck(:person_key, :state, :visitor_id)
  end

  test "a goal's exit is stamped with the server's time, so a retried batch never lets the person back" do
    j = live_journey(@project, re_entry: { "mode" => "after_exit", "days" => nil }, goals: [{ "event" => "checkout", "window_hours" => 168 }],
                               steps: map(step("w", "wait")))
    received = Time.current
    batch = [seen(@ana, "add_to_cart", at: 10.minutes.ago, received: received), seen(@ana, "checkout", at: 9.minutes.ago, received: received)]
    signal(@project, *batch)
    assert_equal "left", row_of(j, @ana).state
    assert_operator row_of(j, @ana).left_at, :>=, received
    signal(@project, *batch)
    assert_equal "left", row_of(j, @ana).state
    travel(1.minute) { signal(@project, seen(@ana, "add_to_cart", at: 8.minutes.ago, received: Time.current)) }
    assert_equal "active", row_of(j, @ana).state, "an entry received after the goal lets them back"
  end

  test "re-entry after exit goes by when the server received the event, not the device's clock" do
    j = live_journey(@project, re_entry: { "mode" => "after_exit", "days" => nil }, steps: map(step("a", "set_attribute", key: "journey_x", value: "1")))
    received = Time.current
    first = seen(@ana, "add_to_cart", at: 10.minutes.ago, received: received)
    signal(@project, first)
    assert_equal "left", row_of(j, @ana).state

    travel(1.minute) { signal(@project, first) }
    assert_equal 1, counts(j)[["", "entered"]], "a retried batch does not take them through again"

    travel(2.minutes) { signal(@project, seen(@ana, "add_to_cart", at: 8.minutes.ago, received: Time.current)) }
    assert_equal 2, counts(j)[["", "entered"]], "a slow device clock still lets a finisher back"
  end

  test "an event the SDK re-sends after the exit does not take the person through again" do
    j = live_journey(@project, re_entry: { "mode" => "after_exit", "days" => nil }, steps: map(step("a", "set_attribute", key: "journey_x", value: "1")))
    at = 10.minutes.ago
    signal(@project, seen(@ana, "add_to_cart", at: at, received: Time.current))
    assert_equal "left", row_of(j, @ana).state

    travel(1.minute) { signal(@project, seen(@ana, "add_to_cart", at: at, received: Time.current)) }
    travel(2.minutes) { signal(@project, seen(@ana, "add_to_cart", at: at - 1.minute, received: Time.current)) }
    assert_equal 1, counts(j)[["", "entered"]], "a re-sent or older offline event is refused"

    travel(3.minutes) { signal(@project, seen(@ana, "add_to_cart", at: at + 1.second, received: Time.current)) }
    assert_equal 2, counts(j)[["", "entered"]], "a newer event lets them back"
  end

  test "an install enters an anonymous person, who stays in the journey once they identify" do
    fresh = visitor
    j = live_journey(@project, entry: ADD_TO_CART.merge("event" => { "system" => "install" }), steps: map(step("w", "wait")))
    signal(@project, seen(fresh, "install"), seen(@ana, "add_to_cart"))
    assert_nil row_of(j, @ana)
    assert_equal "v:#{fresh.id}", JourneyPerson.find_by(journey_id: j.id).person_key

    fresh.update!(sdk_identifier: "newbie")
    JourneyGateway.identified(fresh)
    row = JourneyPerson.find_by(journey_id: j.id)
    assert_equal ["i:newbie", "active", "w", fresh.id], row.values_at(:person_key, :state, :step_id, :visitor_id)
  end

  test "system events enter, end a wait and reach a goal" do
    app_open = { "system" => "app_open" }
    j = live_journey(@project, entry: ADD_TO_CART.merge("event" => app_open), goals: [{ "system" => "reactivation", "window_hours" => 168 }],
                               steps: map(step("w", "wait", until: { kind: "event", event: app_open }, next: "a", timeout_next: nil),
                                          step("a", "set_attribute", key: "journey_back", value: "1", next: "w2"), step("w2", "wait")))
    signal(@project, seen(@ana, "app_open"), seen(@bo, "app_open"))
    assert_equal ["w", "t:app_open"], row_of(j, @ana).values_at(:step_id, :until_event)

    travel(1.minute) { signal(@project, seen(@ana, "app_open")) }
    step_all(j, at: 2.minutes.from_now)
    assert_equal ["w2", "1"], [row_of(j, @ana).step_id, @ana.reload.sdk_attributes["journey_back"]]

    travel(3.minutes) { signal(@project, seen(@bo, "reactivation")) }
    assert_equal ["left", "goal"], row_of(j, @bo).values_at(:state, :left_reason)
  end

  test "people enter at their event's time, so a goal later in the same batch counts" do
    j = live_journey(@project, goals: [{ "event" => "checkout", "window_hours" => 168 }], steps: map(step("w", "wait")))
    ten = 30.minutes.ago
    signal(@project, seen(@ana, "add_to_cart", at: ten), seen(@ana, "checkout", at: ten + 20.seconds))
    assert_equal ["left", "goal"], row_of(j, @ana).values_at(:state, :left_reason)
    assert_in_delta ten, row_of(j, @ana).entered_at, 0.01
  end

  test "the person is resolved when the job runs, so an identify in between enrols them once" do
    anon = visitor
    j = live_journey(@project, steps: map(step("w", "wait")))
    queued = seen(anon, "add_to_cart")
    anon.update!(sdk_identifier: "late")
    signal(@project, queued)
    JourneyGateway.identified(anon)
    assert_equal ["i:late"], JourneyPerson.where(journey_id: j.id).pluck(:person_key)
  end

  test "a goal exit is all or nothing: left, message taken away and counted together" do
    j = live_journey(@project, goals: [{ "event" => "checkout", "window_hours" => 168 }], steps: map(step("i", "in_app")))
    signal(@project, seen(@ana, "add_to_cart"))
    Journeys::Tally.stub(:add, ->(*, **) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_raises(ActiveRecord::StatementInvalid) { travel(1.second) { signal(@project, seen(@ana, "checkout")) } }
    end
    assert_equal "active", row_of(j, @ana).state
    assert SegmentMembership.exists?(segment_key: j.membership_key("i"), visitor_id: @ana.id)
  end

  test "nobody waits past 90 days in the journey" do
    j = live_journey(@project, steps: map(step("w1", "wait", minutes: 5, next: "w2"), step("w2", "wait", minutes: 43_200)))
    signal(@project, seen(@ana, "add_to_cart"))
    row_of(j, @ana).update_columns(entered_at: 89.days.ago)
    step_all(j, at: 10.minutes.from_now)
    row = row_of(j, @ana)
    assert_equal ["w2", row.entered_at + 90.days], [row.step_id, row.due_at]
    step_all(j, at: row.due_at + 1.second)
    assert_equal ["left", "expired"], row_of(j, @ana).values_at(:state, :left_reason)
  end

  test "a late worker whose stale claim was taken over moves nothing, and never releases the new claim" do
    j = live_journey(@project, steps: map(step("w", "wait", minutes: 5, next: "p"), step("p", "push")))
    signal(@project, seen(@ana, "add_to_cart"))
    late = Journeys::Stepper.new(j.reload, now: 10.minutes.from_now)
    plans = late.send(:walk, late.send(:claim, nil))
    row_of(j, @ana).update_columns(state: "active", claimed_at: nil)
    fresh = Journeys::Stepper.new(j.reload, now: 11.minutes.from_now)
    rows = fresh.send(:claim, nil)

    late.send(:commit, plans)
    late.send(:release, rows)
    assert_equal ["claimed", "w"], row_of(j, @ana).values_at(:state, :step_id)
    assert_equal 0, PushDelivery.where(journey_person_id: row_of(j, @ana).id).count

    fresh.send(:commit, fresh.send(:walk, rows))
    assert_equal ["left", "finished"], row_of(j, @ana).values_at(:state, :left_reason)
    assert_equal 1, PushDelivery.where(journey_person_id: row_of(j, @ana).id).count
    assert_equal 1, counts(j)[%w[w next]]
  end

  test "a retried event batch never lets a person back in whom that event already took through the journey" do
    j = live_journey(@project, re_entry: { "mode" => "after_exit", "days" => nil }, steps: map(step("p", "push")))
    batch = [seen(@ana, "add_to_cart")]
    signal(@project, *batch)
    travel(30.seconds) { signal(@project, *batch) }
    assert_equal 1, PushDelivery.where(visitor_id: @ana.id).count
    assert_equal 1, counts(j)[["", "entered"]]

    travel(1.minute) { signal(@project, seen(@ana, "add_to_cart")) }
    assert_equal 2, PushDelivery.where(visitor_id: @ana.id).count, "a new event after the exit lets them back"
  end

  test "an until-opened wait after a quiet-hours push starts its timer when the push goes out" do
    j = live_journey(@project, steps: map(step("p", "push", quiet_hours: true, next: "w"),
                                          step("w", "wait", minutes: 60, until: { kind: "opened", step: "p" }, timeout_next: nil)))
    travel_to(Time.utc(2026, 10, 1, 4, 0)) { signal(@project, seen(@ana, "add_to_cart"), seen(@bo, "add_to_cart")) }
    assert_equal Time.utc(2026, 10, 1, 13, 0), PushDelivery.find_by(journey_person_id: row_of(j, @ana).id).due_at
    assert_equal Time.utc(2026, 10, 1, 14, 0), row_of(j, @ana).due_at
    assert_equal Time.utc(2026, 10, 1, 5, 0), row_of(j, @bo).due_at, "no channel, nothing goes out later"
  end

  test "a wait after two pushes in one pass shifts by the later one" do
    j = live_journey(@project, steps: map(step("p", "push", quiet_hours: true, next: "q"), step("q", "push", next: "w"),
                                          step("w", "wait", minutes: 60)))
    travel_to(Time.utc(2026, 10, 1, 4, 0)) { signal(@project, seen(@ana, "add_to_cart")) }
    assert_equal Time.utc(2026, 10, 1, 14, 0), row_of(j, @ana).due_at
  end

  test "a merge moves the row to the surviving visitor" do
    from = visitor
    j = live_journey(@project, steps: map(step("w", "wait")))
    signal(@project, seen(from, "add_to_cart"))
    JourneyGateway.merge(from: from, to: @bo)
    assert_equal [person(@bo), @bo.id], JourneyPerson.find_by(journey_id: j.id).values_at(:person_key, :visitor_id)
  end
end
