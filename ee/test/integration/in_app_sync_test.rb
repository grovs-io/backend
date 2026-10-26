require "test_helper"
require "sidekiq/testing"
require_relative "../../../test/integration/auth_test_helper"

class InAppSyncTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include InAppFixtures

  fixtures :instances, :projects, :applications, :ios_configurations, :android_configurations, :devices, :visitors, :domains, :redirect_configs

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @headers = sdk_headers_for(@project, @visitor, platform: "ios")
    clear_in_app_stamps(@project)
  end

  def sync(held = {})
    post "#{SDK_PREFIX}/in_app/sync", params: { format: 1, sdk_version: "4.0.0" }.merge(held), headers: @headers, as: :json
    assert_response :ok
    response.parsed_body
  end

  def ids(body) = body["campaigns"].pluck("id")

  test "needs a known device" do
    post "#{SDK_PREFIX}/in_app/sync", params: {}, headers: { "Host" => sdk_host }, as: :json
    assert_response :forbidden
  end

  test "returns live and scheduled campaigns as format 1 definitions, and no drafts, paused or ended ones" do
    live = live_in_app_campaign(@project)
    later = live_in_app_campaign(@project, start_at: 3.days.from_now)
    in_app_campaign(@project)
    live_in_app_campaign(@project).transition!(from: %w[live], to: "paused")
    live_in_app_campaign(@project).end!

    body = sync
    assert_equal [live.hashid, later.hashid], ids(body)
    assert_equal({ "session" => 10, "day" => 10 }, body["global_caps"])
    assert_equal [], body["test_messages"]
    body["campaigns"].each { |definition| assert_empty InAppDefinition.problems(definition) }
    assert_in_delta Time.current.to_f, Time.iso8601(body["server_time"]).to_f, 5
    assert_equal @visitor.created_at.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), body["first_seen_at"]
  end

  test "never returns another project's campaigns" do
    live_in_app_campaign(projects(:two))
    assert_equal [], ids(sync)
  end

  test "answers unchanged to a device that holds both stamps, and in full once a campaign changes" do
    campaign = live_in_app_campaign(@project)
    first = sync
    held = first.slice("campaigns_changed_at", "user_changed_at")
    assert_equal({ "unchanged" => true }, sync(held).except("server_time", "store_url"))

    travel 1.second do
      campaign.update!(priority: 7)
      again = sync(held)
      assert_equal [7], again["campaigns"].pluck("priority")
      assert_not_equal held["campaigns_changed_at"], again["campaigns_changed_at"]
    end
  end

  test "gives each platform the address of its store page, in both kinds of answer" do
    bundle = ios_configurations(:one).bundle_id
    AppstoreService.stub(:fetch_image_and_title_for_identifier, ->(id) { { appstore_id: id == bundle ? "123" : nil } }) do
      first = sync
      assert_equal "https://apps.apple.com/app/id123", first["store_url"]
      assert_equal "https://apps.apple.com/app/id123", sync(first.slice("campaigns_changed_at", "user_changed_at"))["store_url"]
    end

    android = visitors(:android_visitor)
    @headers = sdk_headers_for(@project, android, platform: "android")
    assert_equal "https://play.google.com/store/apps/details?id=#{android_configurations(:one).identifier}", sync["store_url"]
  end

  test "has no store address until the App Store has told us the app's id" do
    AppstoreService.stub(:fetch_image_and_title_for_identifier, { appstore_id: nil }) { assert_nil sync["store_url"] }
    AppstoreService.stub(:fetch_image_and_title_for_identifier, ->(_) { raise Redis::BaseError }) { assert_nil sync["store_url"] }
  end

  test "a device that holds nothing is never told unchanged" do
    assert_nil sync["unchanged"]
    assert_nil sync("campaigns_changed_at" => nil, "user_changed_at" => nil)["unchanged"]
  end

  test "leaves out a campaign whose end has passed although the tick has not run" do
    campaign = live_in_app_campaign(@project, end_at: 1.hour.from_now)
    assert_equal [campaign.hashid], ids(sync)
    travel(2.hours) { assert_equal [], ids(sync) }
  end

  test "leaves out a campaign once the person has reached its lifetime cap" do
    capped = live_in_app_campaign(@project, caps: { "lifetime" => 2 })
    open = live_in_app_campaign(@project)
    InAppViews.record(campaign: capped, visitor: @visitor, event_id: "e1")
    assert_equal [capped.hashid, open.hashid], ids(sync)
    InAppViews.record(campaign: capped, visitor: @visitor, event_id: "e2")
    assert_equal [open.hashid], ids(sync)
  end

  test "reaching the cap moves the stamp of every device of the person" do
    @visitor.update_columns(sdk_identifier: "ana")
    other = Visitor.create!(project: @project, device: devices(:android_device), sdk_identifier: "ana")
    capped = live_in_app_campaign(@project, caps: { "lifetime" => 1 })
    before = InAppStamps.user(other.id)
    InAppViews.record(campaign: capped, visitor: @visitor.reload, event_id: "e1")
    assert_not_equal before, InAppStamps.user(other.id)

    @headers = sdk_headers_for(@project, other, platform: "android")
    assert_equal [], ids(sync)
  end

  test "a segment campaign reaches only the visitors stored as members" do
    segment = Segment.create!(project: @project, name: "S", definition: SEGMENT_DEFINITION)
    campaign = in_app_campaign(@project, audience_type: "segment", segment: segment)
    Sidekiq::Testing.fake! { campaign.launch! }
    campaign.transition!(from: %w[preparing], to: "live")
    assert_equal [], ids(sync)

    SegmentMembership.create!(visitor_id: @visitor.id, segment_key: campaign.segment_key, project_id: @project.id, confirmed_at: Time.current)
    assert_equal [campaign.hashid], ids(sync)
  end

  test "the project switch empties the list and sends the project's own caps" do
    live_in_app_campaign(@project)
    InAppSetting.for(@project).update!(enabled: false, session_cap: 3, day_cap: 4)
    body = sync
    assert_equal [], ids(body)
    assert_equal({ "session" => 3, "day" => 4 }, body["global_caps"])
  end

  test "the global switch empties the list" do
    live_in_app_campaign(@project)
    with_env("IN_APP_ENABLED" => "false") do
      body = sync
      assert_equal [], ids(body)
      assert_equal "off", body["campaigns_changed_at"]
    end
  end

  test "works from Postgres when Redis is down, and never says unchanged" do
    campaign = live_in_app_campaign(@project)
    held = sync.slice("campaigns_changed_at", "user_changed_at")
    InAppStamps.stub(:for, nil) do
      body = sync(held)
      assert_equal [campaign.hashid], ids(body)
      assert_nil body["campaigns_changed_at"]
    end
  end

  test "asks Postgres for nothing about campaigns while the cached list is current" do
    live_in_app_campaign(@project)
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?("in_app_campaigns") }
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      sync
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { assert_equal 1, ids(sync).size }
    end
    assert_empty queries
  end

  private

  test "a device that signs in as a capped person is told to sync and loses the campaign" do
    capped = live_in_app_campaign(@project, caps: { "lifetime" => 1 })
    ana = Visitor.create!(project: @project, device: devices(:android_device), sdk_identifier: "ana")
    InAppViews.record(campaign: capped, visitor: ana, event_id: "e1")
    held = sync.slice("campaigns_changed_at", "user_changed_at")
    assert_equal true, sync(held)["unchanged"]

    post "#{SDK_PREFIX}/visitor_attributes", params: { sdk_identifier: "ana" }, headers: @headers, as: :json
    assert_response :ok
    assert_equal [], ids(sync(held))
  end

  test "views made before signing in count for the person afterwards" do
    capped = live_in_app_campaign(@project, caps: { "lifetime" => 2 })
    @visitor.update_columns(sdk_identifier: nil)
    InAppViews.record(campaign: capped, visitor: @visitor.reload, event_id: "e1")
    ana = Visitor.create!(project: @project, device: devices(:android_device), sdk_identifier: "ana")
    InAppViews.record(campaign: capped, visitor: ana, event_id: "e2")

    post "#{SDK_PREFIX}/visitor_attributes", params: { sdk_identifier: "ana" }, headers: @headers, as: :json
    assert_equal [["i:ana", 2]], InAppView.where(in_app_campaign_id: capped.id).pluck(:person_key, :total)
    assert_equal [], ids(sync)
  end

  test "the store address is looked up once, not at every sync" do
    live_in_app_campaign(@project)
    Rails.cache.delete("in_app:store_url:#{@project.id}:ios")
    sync
    assert_no_queries_match(/applications|ios_configurations/) { sync }
  end

  test "merged visitors are told to sync only after the merge has committed" do
    capped = live_in_app_campaign(@project, caps: { "lifetime" => 1 })
    other = Visitor.create!(project: @project, device: devices(:android_device))
    InAppViews.record(campaign: capped, visitor: other, event_id: "e1")
    before = InAppStamps.user(@visitor.id)
    # The test itself runs in a transaction, so the hook is held here and run by hand.
    held = []
    ActiveRecord.stub(:after_all_transactions_commit, ->(&block) { held << block }) { InAppViews.merge(from: other, to: @visitor) }
    assert_equal before, InAppStamps.user(@visitor.id)
    held.each(&:call)
    assert_not_equal before, InAppStamps.user(@visitor.id)
  end

  test "a transfer of views that failed is finished by the next request, and moves all or nothing" do
    capped = live_in_app_campaign(@project, caps: { "lifetime" => 1 })
    @visitor.update_columns(sdk_identifier: nil)
    InAppViews.record(campaign: capped, visitor: @visitor.reload, event_id: "e1")
    @visitor.update_columns(sdk_identifier: "ana")

    post "#{SDK_PREFIX}/visitor_attributes", params: { sdk_identifier: "ana" }, headers: @headers, as: :json
    assert_equal [["i:ana", 1]], InAppView.where(in_app_campaign_id: capped.id).pluck(:person_key, :total)
    assert_equal [], ids(sync)

    stamp = InAppStamps.user(@visitor.id)
    post "#{SDK_PREFIX}/visitor_attributes", params: { sdk_identifier: "ana" }, headers: @headers, as: :json
    assert_equal stamp, InAppStamps.user(@visitor.id)
  end

  test "a test message reaches every device of the person once, draft or not, and is never counted" do
    @visitor.update_columns(sdk_identifier: "ana")
    other = Visitor.create!(project: @project, device: devices(:android_device), sdk_identifier: "ana")
    draft = in_app_campaign(@project, triggers: [{ "type" => "event", "name" => "never" }], caps: { "lifetime" => 1 })
    held = sync.slice("campaigns_changed_at", "user_changed_at")

    assert_equal 2, InAppTests.deliver(draft, "ana")
    first = sync(held)
    assert_equal [draft.hashid], first["test_messages"].pluck("id")
    assert_equal [], ids(first)
    assert_equal [], sync["test_messages"]

    @headers = sdk_headers_for(@project, other, platform: "android")
    assert_equal [draft.hashid], sync["test_messages"].pluck("id")
    assert_equal 0, InAppView.count
  end

  test "a test message nobody fetched is gone after thirty minutes, longer than a web page's 15 minute sync" do
    @visitor.update_columns(sdk_identifier: "ana")
    InAppTests.deliver(in_app_campaign(@project), "ana")
    assert_in_delta 1800, REDIS.with { |conn| conn.ttl(InAppTests.key(@visitor.id)) }, 2
  end

  test "a campaign whose question the person has answered is left out, on every device of theirs" do
    @visitor.update_columns(sdk_identifier: "ana")
    other = Visitor.create!(project: @project, device: devices(:android_device), sdk_identifier: "ana")
    asked = live_in_app_campaign(@project, content: asking)
    plain = live_in_app_campaign(@project)
    assert_equal asking["question"], sync["campaigns"].first.dig("content", "question")

    InAppViews.answered(campaign: asked, visitor: other)
    assert_equal [plain.hashid], ids(sync)
  end

  test "an answer given before signing in follows the person" do
    @visitor.update_columns(sdk_identifier: nil)
    asked = live_in_app_campaign(@project, content: asking)
    InAppViews.answered(campaign: asked, visitor: @visitor.reload)
    post "#{SDK_PREFIX}/visitor_attributes", params: { sdk_identifier: "ana" }, headers: @headers, as: :json
    assert_equal [["i:ana", true]], InAppView.where(in_app_campaign_id: asked.id).pluck(:person_key, :answered_at).map { |k, at| [k, at.present?] }
    assert_equal [], ids(sync)
  end

  VARIANT_B = { "id" => "b", "content" => { "title" => "Hi there", "message" => "Welcome back" } }.freeze

  def queued_events
    REDIS.with { |conn| conn.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1) }.map { |raw| JSON.parse(raw) }.select { |e| e["event_name"] == "in_app_held" }
  end

  test "a person gets the variant their bucket lands in, with the reserved fields still null" do
    REDIS.with { |conn| conn.del(BatchEventProcessorJob::REDIS_KEY) }
    campaign = live_in_app_campaign(@project, variants: [VARIANT_B])
    group = Experiments::Split.group(Experiments::Bucket.of(campaign.hashid, @visitor.id), control: 0, variants: 2)
    definition = sync["campaigns"].sole
    assert_equal campaign.hashid, definition["id"]
    assert_equal group == "b" ? "Hi there" : "Hello", definition["content"]["title"]
    assert_equal [nil, nil, nil], definition.values_at("variants", "control_group", "conversion")
    assert_empty InAppDefinition.problems(definition)
    assert_equal [], queued_events
  end

  test "a person in the control group gets nothing and is held once a day" do
    REDIS.with { |conn| conn.del(BatchEventProcessorJob::REDIS_KEY) }
    campaign = live_in_app_campaign(@project, variants: [VARIANT_B])
    other = live_in_app_campaign(@project)
    bucket = Experiments::Bucket.of(campaign.hashid, @visitor.id)
    campaign.update_columns(control_group: bucket + 1)
    clear_in_app_stamps(@project)
    assert_equal [other.hashid], ids(sync)
    assert_equal [other.hashid], ids(sync)
    held = queued_events
    assert_equal 1, held.size
    assert_equal({ "campaign_id" => campaign.hashid, "scope" => "campaign" }, held.first["data"])
    assert_equal @visitor.device.id, held.first["device_id"]
  end

  test "a person in the project-wide control group gets no campaign at all" do
    REDIS.with { |conn| conn.del(BatchEventProcessorJob::REDIS_KEY) }
    live_in_app_campaign(@project)
    bucket = Experiments::Bucket.of(@project.hashid, @visitor.id)
    InAppSetting.create!(project: @project, control_group: [bucket + 1, 20].min)
    clear_in_app_stamps(@project)
    if bucket < 20
      assert_equal [], ids(sync)
      assert_equal [{ "scope" => "project" }], queued_events.map { |e| e["data"] }
    else
      assert_equal 1, ids(sync).size
    end
  end

  def with_env(values)
    old = values.keys.index_with { |key| ENV.fetch(key, nil) }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    old.each { |key, value| ENV[key] = value }
  end
end
