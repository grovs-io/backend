require "test_helper"
require "sidekiq/testing"

class JourneyTest < ActiveSupport::TestCase
  include JourneyFixtures
  include InAppFixtures
  fixtures :instances, :projects, :visitors, :devices, :users

  setup do
    @project = projects(:one)
    Sidekiq::Testing.fake!
  end

  teardown { Sidekiq::Testing.disable! }

  def errors_for(**attrs)
    j = Journey.new({ project: @project, name: "J", entry: ADD_TO_CART.deep_dup, first_step: "s1", steps: map(step("s1", "push")) }.merge(attrs))
    j.valid?
    j.errors.full_messages
  end

  test "a draft may start empty, and launch lists what is missing" do
    j = Journey.create!(project: @project, name: "Empty")
    assert_equal ["Choose how people enter", "Add a first step"], j.problems
    assert_raises(Journey::Refused) { j.launch! }
    assert_equal "draft", j.reload.status
  end

  test "a draft from a template may leave its events unchosen; launch asks for them" do
    blank = { "name" => nil, "screen" => nil, "system" => nil, "filters" => [] }
    wait = step("s1", "wait").merge("minutes" => 60, "until" => { "kind" => "event", "event" => blank }, "next" => nil, "timeout_next" => nil)
    j = Journey.create!(project: @project, name: "Template", entry: { "type" => "event", "event" => blank }, first_step: "s1", steps: map(wait))
    assert j.persisted?
    problems = j.problems.join(" | ")
    assert_match(/entry event needs an event/i, problems)
    assert_match(/until event needs an event/i, problems)
    assert_raises(Journey::Refused) { j.launch! }
    assert_empty errors_for(entry: { "type" => "event", "event" => blank }).grep(/needs an event/), "a draft saves"
  end

  test "a draft saves each unfinished part and launch reports it; impossible shapes still refuse" do
    parts = {
      entry: [{ entry: { "type" => "segment", "segment_id" => nil } }, /needs a segment/],
      set_key: [{ steps: map(step("s1", "set_attribute", key: "journey_", value: "x")) }, /key must start/],
      empty_key: [{ steps: map(step("s1", "set_attribute", key: "", value: "x")) }, /key must start/],
      empty_value: [{ steps: map(step("s1", "set_attribute", key: "journey_a", value: "")) }, /value cannot be empty/],
      goal: [{ goals: [{ "event" => "", "window_hours" => 168 }] }, /needs one event/],
      segment: [{ steps: map(step("s1", "split", mode: "condition", condition: { kind: "segment", segment_id: nil }, yes_next: nil, no_next: nil)) },
                /segment that was not found/],
      attribute: [{ steps: map(step("s1", "split", mode: "condition", condition: { kind: "attribute", key: "", op: "eq", value: "x" },
                                    yes_next: nil, no_next: nil)) }, /attribute key/],
      event: [{ steps: map(step("s1", "split", mode: "condition", condition: { kind: "event", event: { name: "" }, days: 7, min_count: 1 },
                                yes_next: nil, no_next: nil)) }, /needs an event/],
      until_step: [{ steps: map(step("s1", "wait", until: { kind: "opened", step: "gone" }, timeout_next: nil)) }, /above it/],
      zero: [{ steps: map(step("s1", "split", mode: "percent", paths: [{ percent: 100, next: nil }, { percent: 0, next: nil }])) }, /at least 1/]
    }
    cond = ->(c) { { steps: map(step("s1", "split", mode: "condition", condition: c, yes_next: nil, no_next: nil)) } }
    parts.merge!(
      blank_filter: [{ entry: ADD_TO_CART.merge("event" => { "name" => "a", "filters" => [{ "field" => "", "op" => "eq", "value" => 1 }] }) },
                     /filter that is not valid/],
      short_wait: [{ steps: map(step("s1", "wait", minutes: 2)) }, /minutes must be/],
      blank_wait: [{ steps: map(step("s1", "wait", minutes: nil)) }, /minutes must be/],
      zero_days: [cond.call({ kind: "event", event: { name: "x" }, days: 0, min_count: nil }), /days must be/],
      zero_count: [cond.call({ kind: "event", event: { name: "x" }, days: 7, min_count: 0 }), /min_count/],
      re_entry: [{ re_entry: { "mode" => "after_days", "days" => 0 } }, /days must be a whole number/],
      platforms: [cond.call({ kind: "platform", values: [] }), /values must be/],
      typed_key: [{ steps: map(step("s1", "set_attribute", key: "pla", value: "x")) }, /key must start/],
      odd_condition_key: [cond.call({ kind: "attribute", key: "pl an", op: "eq", value: "x" }), /attribute key/],
      dashed_key: [{ steps: map(step("s1", "set_attribute", key: "journey-x y", value: "x")) }, /key must start/],
      sum: [{ steps: map(step("s1", "split", mode: "percent", paths: [{ percent: 60, next: nil }, { percent: 30, next: nil }])) }, /add up to 100/],
      odd_field: [{ entry: ADD_TO_CART.merge("event" => { "name" => "a", "filters" => [{ "field" => "order total", "op" => "gt", "value" => 1 }] }) },
                  /filter that is not valid/]
    )
    parts.each do |name, (attrs, launch_error)|
      j = Journey.new({ project: @project, name: "J", entry: ADD_TO_CART.deep_dup, first_step: "s1", steps: map(step("s1", "wait")) }.merge(attrs))
      assert j.save, "#{name}: #{j.errors.full_messages}"
      assert_match launch_error, j.problems.join(" | "), name
    end
    assert_includes errors_for(steps: map(step("s1", "wait", colour: "red"))).join, "unknown fields"
    assert_includes errors_for(steps: map(step("s1", "set_attribute", key: 5, value: "x"))).join, "key must start"
  end

  test "pointers must name steps, and the map may not loop back" do
    assert_includes errors_for(steps: map(step("s1", "push", next: "nope"))).join, "leads to nope, which is not a step"
    loop_map = map(step("s1", "wait", next: "s2"), step("s2", "push", next: "s1"))
    assert_includes errors_for(steps: loop_map).join, "cannot loop back"
    joined = map(step("s1", "split", mode: "percent", paths: [{ percent: 50, next: "s2" }, { percent: 50, next: "s3" }]),
                 step("s2", "wait", next: "s4"), step("s3", "push", next: "s4"), step("s4", "set_attribute", key: "journey_done", value: "yes"))
    assert_empty errors_for(steps: joined), "paths may join"
  end

  test "ids, types, fields and sizes are checked per step" do
    assert_includes errors_for(steps: { "S1" => step("S1", "push") }, first_step: "S1").join, "same id"
    assert_includes errors_for(steps: map(step("s1", "email"))).join, "type must be"
    assert_includes errors_for(steps: map(step("s1", "push", colour: "red"))).join, "unknown fields"
    assert_includes errors_for(steps: map(step("s1", "wait", minutes: 50_000))).join, "minutes must be"
    assert_includes errors_for(steps: map(step("s1", "wait", timeout_next: "s1"))).join, "timeout_next needs an until"
    assert_includes errors_for(steps: map(step("s1", "set_attribute", key: "x" * 60, value: "x"))).join, "journey_"
    assert_includes errors_for(steps: map(step("s1", "in_app", valid_days: 31))).join, "valid_days"
    assert_includes errors_for(steps: map(step("s1", "split", mode: "condition", condition: { kind: "platform", values: ["tv"] }))).join, "values"
    many = (1..61).map { |i| step("s#{i}", "push") }
    assert_includes errors_for(steps: map(*many)).join, "at most 60"
  end

  test "a wait may only wait for a send above it" do
    ok = map(step("s1", "push", next: "s2"), step("s2", "wait", until: { kind: "opened", step: "s1" }, next: nil, timeout_next: nil))
    assert_empty errors_for(steps: ok)
    below = map(step("s1", "wait", until: { kind: "opened", step: "s2" }, next: "s2"), step("s2", "push"))
    assert_includes errors_for(steps: below).join, "above it"
    wrong = map(step("s1", "push", next: "s2"), step("s2", "wait", until: { kind: "clicked", step: "s1" }))
    assert_includes errors_for(steps: wrong).join, "in_app step"
  end

  test "entry, goals, control group and re-entry are checked" do
    assert_includes errors_for(entry: { "type" => "event", "event" => { "name" => "a", "screen" => "b" } }).join, "exactly one"
    assert_includes errors_for(entry: { "type" => "segment", "segment_id" => "nope" }).join, "not found"
    assert_includes errors_for(goals: [{ "event" => "in_app_viewed", "window_hours" => 168 }]).join, "message event"
    assert_includes errors_for(goals: Array.new(4) { { "event" => "x", "window_hours" => 168 } }).join, "at most three"
    assert_includes errors_for(control_group: 51).join, "1 to 50"
    assert_includes errors_for(re_entry: { "mode" => "after_days", "days" => 400 }).join, "days"
    filters = [{ "field" => "value", "op" => "gt", "value" => 20 }, { "field" => "sku", "op" => "is_set" }]
    assert_empty errors_for(entry: ADD_TO_CART.merge("event" => { "name" => "add_to_cart", "filters" => filters }))
    assert_empty errors_for(entry: ADD_TO_CART.merge("event" => { "system" => "install" }), goals: [{ "system" => "reactivation", "window_hours" => 168 }])
    system_filtered = { "system" => "app_open", "filters" => [{ "field" => "value", "op" => "is_set" }] }
    assert_includes errors_for(entry: ADD_TO_CART.merge("event" => system_filtered)).join, "cannot filter a system event"
    assert_includes errors_for(entry: ADD_TO_CART.merge("event" => { "system" => "user_referred" })).join, "system must be one of"
    assert_includes errors_for(entry: ADD_TO_CART.merge("event" => { "system" => "install", "name" => "x" })).join, "exactly one"
    assert_includes errors_for(goals: [{ "system" => "time_spent", "window_hours" => 168 }]).join, "system event"
    bad = [{ "field" => "a-b", "op" => "nope", "value" => 1 }]
    assert_includes errors_for(entry: ADD_TO_CART.merge("event" => { "name" => "a", "filters" => bad })).join, "filter"
  end

  test "an in-app step may use the html template, validated like a campaign's own content" do
    bad = step("s1", "in_app", template: "html", content: { "html" => '<a href="javascript:x">go</a>', "layout" => "modal" })
    j = Journey.create!(project: @project, name: "J", entry: ADD_TO_CART.deep_dup, first_step: "s1", steps: map(bad))
    assert_match(/links to an address/, j.problems.join(" | "))

    good = step("s1", "in_app", template: "html", content: { "html" => "<p>hi</p>", "layout" => "modal" })
    j.update!(steps: map(good))
    assert_empty j.problems
  end

  test "launch creates a live push and in-app campaign per step, hidden from their own lists" do
    j = live_journey(@project, steps: map(step("s1", "push", next: "s2"), step("s2", "in_app")))
    push = PushCampaign.find_by_hashid(j.steps["s1"]["campaign_id"])
    in_app = InAppCampaign.find_by_hashid(j.steps["s2"]["campaign_id"])
    assert_equal %w[live journey visitors], [push.status, push.source, push.audience_type]
    assert_equal ["live", "journey", "j:#{j.hashid}:s2"], [in_app.status, in_app.audience_type, in_app.segment_key]
    assert_equal "live", j.status
    assert_not j.launch!, "only once"
  end

  test "launch refuses a step whose content is not valid, and a 21st live journey" do
    bad = journey(@project, steps: map(step("s1", "push", title: "")))
    error = assert_raises(Journey::Refused) { bad.launch! }
    assert_match(/Step s1: Title can't be blank/, error.message)
    assert_equal 0, PushCampaign.count

    Journey::LIVE_LIMIT.times { live_journey(@project) }
    assert_raises(Journey::Refused) { journey(@project).launch! }
  end

  test "after launch a split may send everyone down one path, which the forks then follow" do
    j = live_journey(@project, steps: map(step("s1", "split", mode: "percent", paths: [{ percent: 50, next: nil }, { percent: 50, next: nil }])))
    steps = j.steps.deep_dup
    steps["s1"]["paths"][0]["percent"] = 0
    steps["s1"]["paths"][1]["percent"] = 100
    assert j.update(steps: steps), j.errors.full_messages.to_sentence
    assert_equal ["path_1"], Journeys::Forks.new(j, {}).decide(j.steps["s1"], (1..50).to_a).values.uniq
  end

  test "after launch only content, timing, percentages and the name may change; campaigns follow the content" do
    j = live_journey(@project, steps: map(step("s1", "wait", minutes: 60, next: "s2"),
                                          step("s2", "split", mode: "percent", paths: [{ percent: 50, next: "s3" }, { percent: 50, next: nil }]),
                                          step("s3", "push")))
    steps = j.steps.deep_dup
    steps["s1"]["minutes"] = 120
    steps["s2"]["paths"][0]["percent"] = 70
    steps["s2"]["paths"][1]["percent"] = 30
    steps["s3"]["title"] = "New title"
    steps["s3"]["campaign_id"] = "forged"
    j.update!(name: "Renamed", steps: steps)
    assert_equal 2, j.revision
    assert_equal "New title", PushCampaign.find_by_hashid(j.steps["s3"]["campaign_id"]).title

    moved = j.steps.deep_dup
    moved["s1"]["next"] = "s3"
    assert_not j.update(steps: moved)
    assert_includes j.errors.full_messages, Journey::LOCKED
    j.reload
    assert_not j.update(goals: [{ "event" => "checkout", "window_hours" => 168 }])
    j.reload
    assert_not j.update(entry: ADD_TO_CART.merge("event" => { "name" => "other" }))
  end

  test "a live journey made through the API takes a timing edit from the dashboard, nulls and empty filters included" do
    j = live_journey(@project, steps: map({ "id" => "w", "type" => "wait", "minutes" => 60, "next" => nil }))
    dashboard = { "w" => { "type" => "wait", "id" => "w", "minutes" => 90, "until" => nil, "timeout_next" => nil, "next" => nil } }
    entry = { "audience_segment_id" => nil, "type" => "event", "segment_id" => nil, "event" => { "filters" => [], "name" => "add_to_cart", "screen" => nil } }
    assert j.update(steps: dashboard, entry: entry), j.errors.full_messages.join
    assert_equal 90, j.reload.steps["w"]["minutes"]
  end

  test "a segment used by a journey counts toward the project's 20 tracked segments" do
    segments = Array.new(InAppCampaign::SEGMENT_KEY_LIMIT) { |i| Segment.create!(project: @project, name: "S#{i}", definition: SEGMENT_DEFINITION) }
    segments.each_with_index do |segment, i|
      campaign = in_app_campaign(@project, audience_type: "segment", segment: segment)
      campaign.update_columns(status: "live", segment_key: "k#{i}")
    end
    extra = Segment.create!(project: @project, name: "Extra", definition: SEGMENT_DEFINITION.merge("operator" => "and"))
    j = journey(@project, entry: ADD_TO_CART.merge("audience_segment_id" => extra.hashid))
    error = assert_raises(Journey::Refused) { j.launch! }
    assert_match(/20 segments/, error.message)
  end

  def reference_all(journey)
    steps = journey.steps.deep_dup
    steps.values.find { |s| s["type"] == "push" }["data"] = journey.images.blobs.to_h { |b| [b.id.to_s, "https://old-cdn.example#{AssetService.path(b)}"] }
    journey.update_column(:steps, steps)
  end

  def media_file(bytes = "\x89PNG\r\n\x1A\n".b, content_type: "image/png", name: "x.png")
    tempfile = Tempfile.new(name, binmode: true)
    tempfile.write(bytes)
    tempfile.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile: tempfile, filename: name, type: content_type)
  end

  # with_lock reloads the row (and so its associations) before the cap is checked: an object loaded before other
  # uploads landed must still see them, not the count it had when it was loaded.
  test "the file count cap is re-checked after the row lock, not from a stale in-memory count" do
    j = journey(@project)
    stale = Journey.find(j.id)
    stale.images.attachments.load
    InAppCampaign::MEDIA_COUNT_LIMIT.times { |i| j.images.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "p#{i}.png", content_type: "image/png") }

    assert_nil stale.attach_image(media_file)
    assert_includes stale.errors[:image], "a journey can hold at most #{InAppCampaign::MEDIA_COUNT_LIMIT} files"
  end

  test "an upload whose expected lock_version is not the locked row's is refused and leaves no blob" do
    j = journey(@project)
    assert_no_difference("ActiveStorage::Blob.count") do
      assert_raises(ActiveRecord::StaleObjectError) { j.attach_image(media_file, expected_version: j.lock_version + 1) }
    end
    assert_not j.reload.images.attached?
  end

  test "an upload queues no analysis, whose blob touch would bump the lock_version it returned" do
    j = journey(@project)
    queued = 0
    ActiveStorage::AnalyzeJob.stub(:perform_later, ->(*) { queued += 1 }) { assert j.attach_image(media_file) }
    assert_equal 0, queued
  end

  test "attach_image returns the address of the file it uploaded, not the newest attached one" do
    j = journey(@project)
    other = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "other.png", content_type: "image/png")
    ActiveStorage::Blob.where(id: other.id).update_all(id: other.id + 1_000_000)
    j.images.attach(ActiveStorage::Blob.find(other.id + 1_000_000))

    url = j.attach_image(media_file(name: "mine.png"))
    assert_match(%r{/mine\.png\z}, url)
  end

  test "fresh files count toward the caps even when no step names them, and a refused upload leaves no blob" do
    j = journey(@project)
    InAppCampaign::MEDIA_COUNT_LIMIT.times { |i| j.images.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "p#{i}.png", content_type: "image/png") }
    assert_no_difference("ActiveStorage::Blob.count") { assert_nil j.attach_image(media_file) }
    assert_includes j.errors[:image], "a journey can hold at most #{InAppCampaign::MEDIA_COUNT_LIMIT} files"
  end

  test "a day-old file no step names is dropped and stops counting; a day-old named one is kept" do
    j = journey(@project)
    InAppCampaign::MEDIA_COUNT_LIMIT.times { |i| j.images.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "p#{i}.png", content_type: "image/png") }
    named = j.images.blobs.first
    ActiveStorage::Blob.where(id: j.images.blobs.select(:id)).update_all(created_at: 2.days.ago)
    steps = j.steps.deep_dup
    steps.values.find { |s| s["type"] == "push" }["data"] = { "a" => "https://old-cdn.example#{AssetService.path(named)}" }
    j.update_column(:steps, steps)

    assert j.attach_image(media_file(name: "new.png"))
    assert_equal [named.id, ActiveStorage::Blob.last.id].sort, j.reload.images.blobs.map(&:id).sort
  end

  test "a copy finds its images by path whatever host the steps stored, and keeps that host" do
    source = journey(@project)
    source.images.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "a.png", content_type: "image/png")
    reference_all(source)
    copy = journey(@project)
    copy.update_column(:steps, source.steps)

    assert copy.copy_images_from(source)
    assert_equal ["https://old-cdn.example#{AssetService.path(copy.images.blobs.first)}"], copy.steps["s1"]["data"].values
  end

  test "a copy finds and rewrites proxy-form addresses and filenames with an ampersand" do
    source = journey(@project)
    source.images.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "a&b.png", content_type: "image/png")
    proxy = "https://cdn.example#{AssetService.path(source.images.blobs.first).sub('/redirect/', '/proxy/')}"
    source.update_column(:steps, source.steps.deep_merge("s1" => { "data" => { "a" => proxy } }))
    copy = journey(@project)
    copy.update_column(:steps, source.steps)

    assert copy.copy_images_from(source)
    assert_equal ["https://cdn.example#{AssetService.path(copy.images.blobs.first).sub('/redirect/', '/proxy/')}"], copy.steps["s1"]["data"].values
  end
end
