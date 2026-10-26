require "test_helper"
require "sidekiq/testing"

class JourneyJobsTest < ActiveSupport::TestCase
  include JourneyFixtures
  include ConstStubHelper
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    @ana = visitors(:ios_visitor)
    devices(:ios_device).update_columns(push_token: "tok-ios")
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
    @apns = Rpush::Apnsp8::App.create!(name: "t-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
  end

  teardown do
    Sidekiq::Testing.disable!
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
    REDIS.with { |c| (c.keys("push:cap:*") + c.keys("journeys:step:*") + [BatchEventProcessorJob::REDIS_KEY]).each { |k| c.del(k) } }
  end

  def campaign(name = "c")
    c = PushCampaign.create!(project: @project, name: name, title: "t", body: "b", status: "sending", audience_type: "visitors", recipients: [@ana.uuid])
    PushCampaigns::Audience.freeze!(c)
    c
  end

  def used = REDIS.with { |c| c.keys("push:cap:*").map { |k| c.get(k).to_i } }.reject(&:zero?)

  def deliver(push) = RpushService.stub(:app_for_platform, @apns) { PushCampaigns::Deliverer.new(push).deliver_slice }

  test "the daily cap stops pushes past N per person and UTC day, across campaigns, as capped failures" do
    InAppSetting.create!(project: @project, push_daily_cap: 1)
    first = campaign("first")
    second = campaign("second")
    deliver(first)
    deliver(second)
    assert_equal "queued", first.deliveries.first.status
    assert_equal %w[failed capped], second.deliveries.first.values_at(:status, :error)
    assert_equal [1, { "capped" => 1 }], [second.reload.failed, second.error_counts]
    assert_equal 1, Rpush::Apnsp8::Notification.count

    travel(1.day) do
      third = campaign("third")
      deliver(third)
      assert_equal "queued", third.deliveries.first.status
    end
  end

  test "without a cap nothing is counted" do
    deliver(campaign)
    assert_empty REDIS.with { |c| c.keys("push:cap:*") }
  end

  test "a journey's push campaign is delivered while live and never closed" do
    j = live_journey(@project)
    signal(@project, seen(@ana, "add_to_cart"))
    push = PushCampaign.find_by_hashid(j.steps["s1"]["campaign_id"])
    RpushService.stub(:app_for_platform, @apns) { PushCampaignDeliverJob.new.perform(push.id, 0) }
    assert_equal ["live", "queued"], [push.reload.status, push.deliveries.first.status]

    PushDelivery.where(push_campaign_id: push.id).update_all(status: "pending")
    PushCampaignDeliverJob.clear
    PushCampaignTickJob.new.perform
    assert_equal [push.id], PushCampaignDeliverJob.jobs.map { |job| job["args"].first }.uniq
  end

  test "the purge takes journey delivery rows older than 30 days by age" do
    j = live_journey(@project)
    signal(@project, seen(@ana, "add_to_cart"))
    push_id = PushCampaign.decode_id(j.steps["s1"]["campaign_id"])
    PushDelivery.where(push_campaign_id: push_id).update_all(created_at: 31.days.ago)
    signal(@project, seen(visitors(:android_visitor), "add_to_cart"))
    PushCampaignPurgeJob.new.perform
    assert_equal [visitors(:android_visitor).id], PushDelivery.where(push_campaign_id: push_id).pluck(:visitor_id)
  end

  test "a step job holds its slot, and one step job at a time works a slot" do
    j = live_journey(@project, steps: map(step("w", "wait", minutes: 5)))
    REDIS.with { |c| c.set(JourneyStepJob.slot_key(j.id, 0), "other", ex: 60) }
    Journeys::Stepper.stub(:new, ->(*) { flunk "must not run" }) { JourneyStepJob.new.perform(j.id, 0) }
    REDIS.with { |c| c.del(JourneyStepJob.slot_key(j.id, 0)) }
    signal(@project, seen(@ana, "add_to_cart"))
    travel(10.minutes) { JourneyStepJob.new.perform(j.id, 0) }
    assert_equal "finished", row_of(j, @ana).left_reason
    assert_nil REDIS.with { |c| c.get(JourneyStepJob.slot_key(j.id, 0)) }
  end

  test "the kill switch stops the jobs and the gateway" do
    j = live_journey(@project, steps: map(step("w", "wait", minutes: 5)))
    ENV["JOURNEYS_ENABLED"] = "false"
    JourneyEventJob.new.perform(@project.id, [seen(@ana, "add_to_cart")])
    assert_nil row_of(j, @ana)
    JourneyTickJob.new.perform
    assert_empty JourneyStepJob.jobs
  ensure
    ENV.delete("JOURNEYS_ENABLED")
  end

  test "the event job lets people in through the gateway's payload, judging re-entry by its receive time" do
    j = live_journey(@project, re_entry: { "mode" => "after_exit", "days" => nil }, steps: map(step("w", "wait", minutes: 5)))
    JourneyEventJob.new.perform(@project.id, JSON.parse([seen(@ana, "add_to_cart")].to_json))
    assert_equal "active", row_of(j, @ana).state, "a row without a receive time, as queued before the deploy, still works"

    left = row_of(j, @ana)
    left.update_columns(state: "left", entered_at: 10.minutes.ago, left_at: Time.current, left_reason: "finished", due_at: nil)
    travel(1.minute) { JourneyEventJob.new.perform(@project.id, JSON.parse([seen(@ana, "add_to_cart", at: 5.minutes.ago)].to_json)) }
    assert_equal "left", left.reload.state, "without a receive time the event's own time decides"
    travel(1.minute) { JourneyEventJob.new.perform(@project.id, JSON.parse([seen(@ana, "add_to_cart", at: 5.minutes.ago, received: Time.current)].to_json)) }
    assert_equal "active", left.reload.state
  end

  test "the membership refresh fans out to journeys, never to their step campaigns, and cleanup keeps their keys" do
    segment = Segment.create!(project: @project, name: "VIP", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    j = live_journey(@project, entry: ADD_TO_CART.merge("audience_segment_id" => segment.hashid), steps: map(step("i", "in_app")))
    InAppMembershipRefreshJob.clear
    InAppMembershipRefreshJob.new.perform
    assert_equal [[nil, j.id]], InAppMembershipRefreshJob.jobs.map { |job| job["args"] }

    key = j.segment_keys[segment.hashid]["key"]
    [key, j.membership_key("i"), "gone"].each do |k|
      SegmentMembership.create!(visitor_id: @ana.id, segment_key: k, project_id: @project.id, confirmed_at: Time.current)
    end
    InAppMemberships.cleanup
    assert_equal [j.membership_key("i"), key].sort, SegmentMembership.pluck(:segment_key).sort
  end

  test "the cap counts only pushes handed to rpush: not a cancelled slice, not one that failed and was retried" do
    InAppSetting.create!(project: @project, push_daily_cap: 1)
    cancelled = campaign("cancelled")
    cancelled.update_column(:status, "cancelled")
    assert_not deliver(cancelled)
    assert_empty used

    retried = campaign("retried")
    original = PushCampaigns::Deliverer.instance_method(:persist)
    PushCampaigns::Deliverer.define_method(:persist) { |*| raise ActiveRecord::StatementInvalid, "boom" }
    assert_raises(ActiveRecord::StatementInvalid) { deliver(retried) }
    PushCampaigns::Deliverer.define_method(:persist, original)
    original = nil
    assert_empty used
    retried.deliveries.update_all(status: "pending")
    deliver(retried)
    assert_equal "queued", retried.deliveries.first.status
    assert_equal [1], used
  ensure
    PushCampaigns::Deliverer.define_method(:persist, original) if original
  end

  test "an ended journey is not finished while its pushes still wait to go out" do
    j = live_journey(@project)
    signal(@project, seen(@ana, "add_to_cart"))
    j.end!
    JourneyTickJob.new.perform
    assert_nil j.reload.finished_at
    PushDelivery.where(push_campaign_id: j.channel_ids("push")).update_all(status: "queued")
    JourneyTickJob.new.perform
    assert_not_nil j.reload.finished_at
  end

  test "pause holds the journey's pushes and in-app messages; resume and end release them" do
    j = live_journey(@project, steps: map(step("p", "push", next: "i"), step("i", "in_app")))
    signal(@project, seen(@ana, "add_to_cart"))
    push = PushCampaign.find(j.channel_ids("push").first)
    in_app = InAppCampaign.find(j.channel_ids("in_app").first)
    j.pause!
    assert_equal %w[paused paused], [push.reload.status, in_app.reload.status]
    PushCampaignDeliverJob.clear
    PushCampaignTickJob.new.perform
    RpushService.stub(:app_for_platform, @apns) { PushCampaignDeliverJob.new.perform(push.id, 0) }
    assert_empty PushCampaignDeliverJob.jobs
    assert_equal "pending", push.deliveries.first.status

    j.resume!
    PushCampaignTickJob.new.perform
    assert_equal [push.id], PushCampaignDeliverJob.jobs.map { |job| job["args"].first }.uniq
    j.pause!
    j.end!
    assert_equal %w[live live], [push.reload.status, in_app.reload.status]
  end

  test "in-app campaign limit leaves out journey steps; the tracked segment count includes ended journeys still running" do
    chain = (1..InAppCampaign::ACTIVE_LIMIT).map { |i| step("i#{i}", "in_app", next: i < InAppCampaign::ACTIVE_LIMIT ? "i#{i + 1}" : nil) }
    live_journey(@project, steps: map(*chain))
    assert InAppCampaign.create!(project: @project, name: "Own", content: { "title" => "Hi" }, triggers: [{ "type" => "app_open" }]).launch!

    segment = Segment.create!(project: @project, name: "VIP", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    ended = live_journey(@project, entry: ADD_TO_CART.merge("audience_segment_id" => segment.hashid), steps: map(step("w", "wait")))
    ended.end!
    assert_includes InAppMemberships.tracked_keys(@project.id), ended.segment_keys[segment.hashid]["key"]
  end

  test "segment entry sweeps in members once entry opens: at the start time and on resume" do
    segment = Segment.create!(project: @project, name: "New", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    entry = { "type" => "segment", "event" => nil, "segment_id" => segment.hashid, "audience_segment_id" => nil }
    j = live_journey(@project, entry: entry, start_at: 1.hour.from_now, steps: map(step("w", "wait")))
    key = j.segment_keys["entry"]["key"]
    SegmentMembership.create!(visitor_id: @ana.id, segment_key: key, project_id: @project.id, confirmed_at: Time.current)
    Journeys.admit(j, [@ana.id])
    assert_nil row_of(j, @ana)

    JourneySweepJob.clear
    travel(2.hours) do
      JourneyTickJob.new.perform
      assert_equal [[j.id]], JourneySweepJob.jobs.map { |job| job["args"] }
      JourneySweepJob.drain
      assert_equal "active", row_of(j, @ana).state
      JourneyTickJob.new.perform
      assert_empty JourneySweepJob.jobs, "once"

      bo = visitors(:android_visitor)
      j.reload.pause!
      SegmentMembership.create!(visitor_id: bo.id, segment_key: key, project_id: @project.id, confirmed_at: Time.current)
      Journeys.admit(j.reload, [bo.id])
      assert_nil row_of(j, bo)
      j.resume!
      JourneySweepJob.drain
      assert_equal "active", row_of(j, bo).state
    end
  end

  test "identify costs no query in a project without unfinished journeys" do
    JourneyGateway.identified(@ana)
    sql = []
    ActiveSupport::Notifications.subscribed(->(*, payload) { sql << payload[:sql] unless payload[:name] == "SCHEMA" }, "sql.active_record") do
      JourneyGateway.identified(@ana)
    end
    assert_empty sql
  end

  test "step loops across all journeys are capped; a job over the cap stops and leaves it to the tick" do
    j = live_journey(@project, steps: map(step("w", "wait", minutes: 5)))
    JourneyStepJob.max_workers.times { |i| REDIS.with { |c| c.set(JourneyStepJob.worker_key(i), "busy", ex: 60) } }
    Journeys::Stepper.stub(:new, ->(*) { flunk "over the cap" }) { JourneyStepJob.new.perform(j.id, 0) }
    assert_empty JourneyStepJob.jobs
    assert_nil REDIS.with { |c| c.get(JourneyStepJob.slot_key(j.id, 0)) }, "the slot is let go"
    assert_equal %w[journeys journeys journeys], [JourneyStepJob, JourneyEventJob, JourneySweepJob].map { |k| k.get_sidekiq_options["queue"].to_s }
  end

  test "a report reads who is inside at most once a minute" do
    j = live_journey(@project, steps: map(step("w", "wait", minutes: 5)))
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      signal(@project, seen(@ana, "add_to_cart"))
      assert_equal 1, Journeys::Report.call(j, from: Date.current.iso8601, to: Date.current.iso8601)["active"]
      signal(@project, seen(visitors(:android_visitor), "add_to_cart"))
      assert_equal 1, Journeys::Report.call(j, from: Date.current.iso8601, to: Date.current.iso8601)["active"]
      travel(61.seconds) { assert_equal 2, Journeys::Report.call(j, from: Date.current.iso8601, to: Date.current.iso8601)["active"] }
    end
  end

  test "an edit updates only the campaigns of steps whose content changed" do
    j = live_journey(@project, steps: map(step("p", "push", next: "i"), step("i", "in_app")))
    in_app = InAppCampaign.find(j.channel_ids("in_app").first)
    stamp = InAppStamps.campaigns(@project.id)
    read = []
    watch = ->(*, payload) { read << payload[:sql] if payload[:sql].include?("in_app_campaigns") }
    travel(1.minute) do
      steps = j.steps.deep_dup
      steps["p"]["title"] = "Changed"
      ActiveSupport::Notifications.subscribed(watch, "sql.active_record") { j.update!(steps: steps, name: "Renamed") }
    end
    assert_empty read, "the in-app step's campaign is not even loaded"
    assert_equal "Changed", PushCampaign.find(j.channel_ids("push").first).title
    assert_equal [in_app.updated_at, 1], [in_app.reload.updated_at, in_app.revision]
    assert_equal stamp, InAppStamps.campaigns(@project.id)
  end

  test "the cap is reserved atomically: two slices reading at once cannot both take the last push" do
    InAppSetting.create!(project: @project, push_daily_cap: 1)
    row = { "id" => 1, "visitor_id" => @ana.id }
    first = PushCampaigns::Deliverer.new(campaign("a"))
    second = PushCampaigns::Deliverer.new(campaign("b"))
    assert_empty first.send(:reserve, [row], Time.current)
    assert_equal [row], second.send(:reserve, [row], Time.current)
    assert_equal [1], used
  end

  test "an entry sweep admits only people never in the journey, and opening entry is retried until the sweep starts" do
    segment = Segment.create!(project: @project, name: "New", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    entry = { "type" => "segment", "event" => nil, "segment_id" => segment.hashid, "audience_segment_id" => nil }
    steps = map(step("a", "set_attribute", key: "journey_x", value: "1"))
    j = live_journey(@project, entry: entry, re_entry: { "mode" => "after_exit", "days" => nil }, steps: steps)
    assert_nil j.reload.entry_opened_at
    JourneySweepJob.clear
    JourneyTickJob.new.perform
    assert_equal [[j.id]], JourneySweepJob.jobs.map { |job| job["args"] }, "the tick enqueues again until the sweep runs"
    JourneySweepJob.drain
    assert_not_nil j.reload.entry_opened_at

    key = j.segment_keys["entry"]["key"]
    SegmentMembership.create!(visitor_id: @ana.id, segment_key: key, project_id: @project.id, confirmed_at: Time.current)
    Journeys.admit(j, [@ana.id])
    step_all(j)
    finished = row_of(j, @ana).entered_at
    assert_equal "left", row_of(j, @ana).state
    j.pause!
    j.resume!
    JourneySweepJob.drain
    assert_equal ["left", finished], row_of(j, @ana).values_at(:state, :entered_at), "nobody who finished comes back"
  end

  test "a journey's segment refresh brings the audience segment up to date before newcomers are let in" do
    audience = Segment.create!(project: @project, name: "Buyers", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    entering = Segment.create!(project: @project, name: "New", definition: PushCampaignFixtures::SEGMENT_DEFINITION.merge("operator" => "and"))
    entry = { "type" => "segment", "event" => nil, "segment_id" => entering.hashid, "audience_segment_id" => audience.hashid }
    j = live_journey(@project, entry: entry, steps: map(step("w", "wait")))
    order = []
    refresh = lambda do |tracked, entered:, **|
      order << tracked.segment_key
      SegmentMembership.create!(visitor_id: @ana.id, segment_key: tracked.segment_key, project_id: @project.id, confirmed_at: Time.current)
      entered&.call([@ana.id])
    end
    InAppMemberships.stub(:refresh, refresh) { InAppMembershipRefreshJob.new.perform(nil, j.id) }
    assert_equal [j.segment_keys[audience.hashid]["key"], j.segment_keys["entry"]["key"]], order
    assert_equal "active", row_of(j, @ana).state
  end

  test "an event journey that lets people back after they leave keeps a leaver's row a day, and still lets them back" do
    j = live_journey(@project, re_entry: { "mode" => "after_exit", "days" => nil }, steps: map(step("a", "set_attribute", key: "journey_x", value: "1")))
    signal(@project, seen(@ana, "add_to_cart"))
    assert_equal ["left", "finished"], row_of(j, @ana).values_at(:state, :left_reason)
    travel(1.minute) { signal(@project, seen(@ana, "add_to_cart")) }
    assert_equal({ ["", "entered"] => 2, ["", "finished"] => 2 }, counts(j).slice(["", "entered"], ["", "finished"]))

    held = live_journey(@project, re_entry: { "mode" => "after_exit", "days" => nil }, control_group: 50, steps: map(step("w", "wait")))
    people = Array.new(10) { Visitor.create!(project: @project, device: devices(:web_device)) }
    signal(@project, *people.map { |v| seen(v, "add_to_cart") })
    assert_operator counts(held)[["", "held"]].to_i, :positive?

    goal = live_journey(@project, re_entry: { "mode" => "after_exit", "days" => nil }, goals: [{ "event" => "checkout", "window_hours" => 168 }],
                                  steps: map(step("w", "wait")))
    signal(@project, seen(@ana, "add_to_cart"))
    travel(1.second) { signal(@project, seen(@ana, "checkout")) }
    assert_equal ["left", "goal"], row_of(goal, @ana).values_at(:state, :left_reason)
    assert_equal 1, counts(goal)[["", "goal"]]

    JourneyPerson.where(journey_id: [j.id, held.id, goal.id]).update_all(left_at: 2.days.ago)
    JourneyPruneJob.new.perform
    assert_nil row_of(j, @ana)
    assert_nil row_of(goal, @ana)
    assert_equal JourneyPerson.where(journey_id: held.id, left_reason: "held").count, counts(held)[["", "held"]], "held rows stay: they never come back"
  end

  test "the nightly prune keeps what re-entry needs and drops the rest, leaving the numbers alone" do
    bo = visitors(:android_visitor)
    days = live_journey(@project, re_entry: { "mode" => "after_days", "days" => 3 }, steps: map(step("a", "set_attribute", key: "journey_x", value: "1")))
    once = live_journey(@project, steps: map(step("a", "set_attribute", key: "journey_x", value: "1")))
    done = live_journey(@project, steps: map(step("a", "set_attribute", key: "journey_x", value: "1")))
    signal(@project, seen(@ana, "add_to_cart"), seen(bo, "add_to_cart"))
    row_of(days, @ana).update_columns(left_at: 4.days.ago)
    JourneyPerson.where(journey_id: once.id).update_all(left_at: 400.days.ago)
    done.end!
    JourneyTickJob.new.perform
    report = Journeys::Report.call(days, from: Date.current.iso8601, to: Date.current.iso8601)
    listed = JourneySerializer.stats([days, done])

    JourneyPruneJob.new.perform
    assert_equal [bo.id], JourneyPerson.where(journey_id: days.id).pluck(:visitor_id)
    assert_equal 2, JourneyPerson.where(journey_id: once.id).count
    assert_equal 0, JourneyPerson.where(journey_id: done.id).count
    assert_equal report, Journeys::Report.call(days, from: Date.current.iso8601, to: Date.current.iso8601)
    assert_equal listed, JourneySerializer.stats([days, done])

    signal(@project, seen(@ana, "add_to_cart"))
    assert_equal "left", row_of(days, @ana).state, "let back in after the prune, and through the path again"
    assert_operator row_of(days, @ana).entered_at, :>, 1.minute.ago
  end

  test "the nightly cleanup drops the views of campaigns ended a month ago and keeps the rest" do
    make = lambda do |status, ended_at|
      c = InAppCampaign.create!(project: @project, name: status, content: { "title" => "Hi" }, triggers: [{ "type" => "app_open" }])
      c.update_columns(status: status, launched_at: 40.days.ago, ended_at: ended_at)
      InAppView.create!(in_app_campaign_id: c.id, person_key: "v:1", project_id: @project.id, total: 1, updated_at: Time.current)
      c
    end
    old = make.call("ended", 31.days.ago)
    recent = make.call("ended", 5.days.ago)
    live = make.call("live", nil)
    InAppMembershipCleanupJob.new.perform
    assert_equal [recent.id, live.id].sort, InAppView.where(in_app_campaign_id: [old.id, recent.id, live.id]).pluck(:in_app_campaign_id).sort
    InAppMembershipCleanupJob.new.perform(["some-key"])
    assert_equal 2, InAppView.where(in_app_campaign_id: [recent.id, live.id]).count
  end

  test "the prune spends its budget only on deletes, so journeys past the first twenty still get pruned" do
    empty = Array.new(JourneyPruneJob::MAX_BATCHES + 5) { live_journey(@project, re_entry: { "mode" => "after_days", "days" => 3 }).tap(&:end!) }
    last = live_journey(@project, re_entry: { "mode" => "after_days", "days" => 3 })
    signal(@project, seen(@ana, "add_to_cart"))
    JourneyPerson.where(journey_id: last.id).update_all(left_at: 5.days.ago)
    JourneyPerson.where(journey_id: empty.map(&:id)).delete_all
    JourneyPruneJob.new.perform
    assert_equal 0, JourneyPerson.where(journey_id: last.id).count
  end

  test "each kind of prune has its own nightly budget, so many leavers never starve a finished journey" do
    exit = live_journey(@project, re_entry: { "mode" => "after_exit", "days" => nil }, steps: map(step("a", "set_attribute", key: "journey_x", value: "1")))
    people = Array.new(3) { Visitor.create!(project: @project, device: devices(:web_device)) }
    signal(@project, *people.map { |v| seen(v, "add_to_cart") })
    done = live_journey(@project, steps: map(step("w", "wait")))
    signal(@project, seen(@ana, "add_to_cart"))
    done.end!
    JourneyPerson.where(journey_id: done.id).update_all(state: "left")
    JourneyTickJob.new.perform
    JourneyPerson.where(journey_id: exit.id).update_all(left_at: 2.days.ago)
    leavers = JourneyPerson.where(journey_id: exit.id).count
    with_const(JourneyPruneJob, :BATCH, 1) { with_const(JourneyPruneJob, :MAX_BATCHES, 1) { JourneyPruneJob.new.perform } }
    assert_equal leavers - 1, JourneyPerson.where(journey_id: exit.id).count
    assert_equal 0, JourneyPerson.where(journey_id: done.id).count
  end

  test "a held person in an after_exit journey keeps their row and is counted once" do
    j = live_journey(@project, re_entry: { "mode" => "after_exit", "days" => nil }, control_group: 50, steps: map(step("w", "wait")))
    held = Array.new(20) { Visitor.create!(project: @project, device: devices(:web_device)) }.find { |v| Experiments::Bucket.of(j.hashid, v.id) < 50 }
    signal(@project, seen(held, "add_to_cart"))
    travel(1.minute) { signal(@project, seen(held, "add_to_cart")) }
    assert_equal ["left", "held"], row_of(j, held).values_at(:state, :left_reason)
    assert_equal 1, counts(j)[["", "held"]]
  end
end
