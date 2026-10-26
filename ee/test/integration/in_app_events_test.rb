require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class InAppEventsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include InAppFixtures

  fixtures :instances, :projects, :applications, :ios_configurations, :android_configurations, :devices, :visitors, :domains, :redirect_configs

  BUTTONS = [{ "id" => "shop", "text" => "Shop", "action" => { "type" => "close" } }].freeze

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @headers = sdk_headers_for(@project, @visitor, platform: "ios")
    clear_in_app_stamps(@project)
    REDIS.with { |conn| conn.del(BatchEventProcessorJob::REDIS_KEY) }
    @campaign = live_in_app_campaign(@project, content: CONTENT.merge("buttons" => BUTTONS), caps: { "lifetime" => 5 })
  end

  def batch(*events)
    post "#{SDK_PREFIX}/events/batch", params: { events: events }, headers: @headers, as: :json
    assert_response :ok
    response.parsed_body
  end

  def viewed(id, campaign = @campaign.hashid)
    { event_name: "in_app_viewed", event_id: id, properties: { campaign_id: campaign, revision: 1, template: "interstitial" } }
  end

  def total = InAppView.find_by(in_app_campaign_id: @campaign.id)&.total

  test "a view is accepted, queued as an event under its id, and counted for the person" do
    id = SecureRandom.uuid
    body = batch(viewed(id))
    assert_equal [1, 0], body.values_at("accepted", "rejected")
    queued = REDIS.with { |conn| conn.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1) }.map { |raw| JSON.parse(raw) }
    assert_equal ["in_app_viewed"], queued.pluck("event_name")
    assert_equal [id], InAppView.find_by(in_app_campaign_id: @campaign.id).recent
    assert_equal 1, total
  end

  test "a replayed batch counts each view once" do
    ids = Array.new(2) { SecureRandom.uuid }
    2.times { batch(*ids.map { |id| viewed(id) }) }
    assert_equal 2, total
  end

  test "a click and a dismissal are accepted and counted nowhere" do
    clicked = { event_name: "in_app_clicked", properties: { campaign_id: @campaign.hashid, button_id: "shop", action: "close" } }
    tapped = { event_name: "in_app_clicked", properties: { campaign_id: @campaign.hashid, action: "open_url" } }
    dismissed = { event_name: "in_app_dismissed", properties: { campaign_id: @campaign.hashid, reason: "swipe" } }
    assert_equal 3, batch(clicked, tapped, dismissed)["accepted"]
    assert_nil total
  end

  test "forged events are refused one by one and the rest of the batch goes through" do
    draft = in_app_campaign(@project)
    foreign = live_in_app_campaign(projects(:two))
    body = batch(viewed(SecureRandom.uuid, "nope"), viewed(SecureRandom.uuid, draft.hashid), viewed(SecureRandom.uuid, foreign.hashid),
                 { event_name: "in_app_viewed", properties: {} },
                 { event_name: "in_app_clicked", properties: { campaign_id: @campaign.hashid, button_id: "ghost" } },
                 { event_name: "cart_viewed" })
    assert_equal [1, 5], body.values_at("accepted", "rejected")
    assert_equal [0, 1, 2, 3, 4], body["errors"].pluck("index")
    assert_nil total
    assert_equal 0, InAppView.count
  end

  test "the names the server writes itself are refused from a device" do
    mine = { campaign_id: @campaign.hashid }
    body = batch(*%w[in_app_held push_delivered push_held].map { |name| { event_name: name, event_id: SecureRandom.uuid, properties: mine } })
    assert_equal [0, 3], body.values_at("accepted", "rejected")
    assert_equal [], REDIS.with { |conn| conn.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1) }
  end

  test "the single event endpoint refuses the three names" do
    post "#{SDK_PREFIX}/event/custom", params: { event_name: "in_app_viewed", properties: { campaign_id: @campaign.hashid } }, headers: @headers, as: :json
    assert_response :bad_request
    assert_nil total
  end

  test "every batch response carries the two stamps, and they match what sync sends" do
    stamps = batch({ event_name: "cart_viewed" })["in_app"]
    post "#{SDK_PREFIX}/in_app/sync", params: { format: 1 }, headers: @headers, as: :json
    assert_equal response.parsed_body.slice("campaigns_changed_at", "user_changed_at"), stamps
  end

  test "switched off, the stamps say so, so a device syncs and empties itself at once" do
    held = batch({ event_name: "cart_viewed" })["in_app"]
    ENV["IN_APP_ENABLED"] = "false"
    off = batch({ event_name: "cart_viewed" })["in_app"]
    assert_equal({ "campaigns_changed_at" => "off", "user_changed_at" => "off" }, off)
    assert_not_equal held, off

    batch(viewed(SecureRandom.uuid))
    assert_nil total
  ensure
    ENV.delete("IN_APP_ENABLED")
  end
  test "a full batch for one campaign, sent twice, counts each view once" do
    @campaign.update_columns(caps: { "lifetime" => 500 })
    ids = Array.new(50) { SecureRandom.uuid }
    2.times { batch(*ids.map { |id| viewed(id) }) }
    assert_equal 50, total
  end

  test "a click from a device on an older revision may name a button since renamed" do
    @campaign.update!(content: CONTENT.merge("buttons" => [BUTTONS.first.merge("id" => "buy")]))
    click = lambda { |revision, id|
      { event_name: "in_app_clicked", properties: { campaign_id: @campaign.hashid, revision: revision, button_id: id, action: "close" } }
    }
    refused = batch(click.call(1, "shop"), click.call(@campaign.revision, "shop"), click.call(1, "<script>"))
    assert_equal 1, InAppEventCheck.accept(project: @project, visitor: @visitor, name: "in_app_clicked", event_id: "e",
                                           properties: click.call(1, "shop")[:properties].stringify_keys) ? 1 : 0
    assert_not InAppEventCheck.accept(project: @project, visitor: @visitor, name: "in_app_clicked", event_id: "e",
                                      properties: click.call(@campaign.revision, "shop")[:properties].stringify_keys)
    assert_not InAppEventCheck.accept(project: @project, visitor: @visitor, name: "in_app_clicked", event_id: "e",
                                      properties: click.call(1, "<script>")[:properties].stringify_keys)
    assert refused
  end

  def answered(value, campaign: @asking, **more)
    { event_name: "in_app_answered", event_id: SecureRandom.uuid,
      properties: { campaign_id: campaign.hashid, revision: campaign.revision, question_id: "q1", type: "stars", value: value }.merge(more) }
  end

  def accepted?(event) = batch(event)["accepted"].to_i == 1

  # Forgets the person's answers, so one test can send several first answers.
  def again! = InAppView.delete_all

  test "an answer is accepted when it fits the question, and refused when it does not" do
    @asking = live_in_app_campaign(@project, content: asking)
    assert accepted?(answered(1))
    again!
    assert accepted?(answered(5))
    again!
    [0, 6, 3.5, "4", nil, "search"].each { |value| assert_not accepted?(answered(value)), value.inspect }
    assert_not accepted?(answered(4, campaign: @campaign))

    choice = live_in_app_campaign(@project, content: asking(CHOICE))
    assert accepted?(answered("friend", campaign: choice))
    assert_not accepted?(answered("nobody", campaign: choice))
    assert_not accepted?(answered(3, campaign: choice))
  end

  test "a comment needs words, an answer that fits, and at most a thousand characters" do
    @asking = live_in_app_campaign(@project, content: asking)
    assert accepted?(answered(2))
    comment = ->(text, value = 2) { answered(value, comment: text).merge(event_name: "in_app_commented") }
    assert accepted?(comment.call("Too slow"))
    assert accepted?(comment.call("x" * 1_000))
    ["", "   ", nil, 5, "x" * 1_001].each { |text| assert_not accepted?(comment.call(text)), text.inspect[0, 20] }
    assert_not accepted?(comment.call("Fine", 9))
  end

  test "the first answer is remembered for the person, tells their devices once, and counts as no view" do
    @asking = live_in_app_campaign(@project, content: asking)
    before = InAppStamps.user(@visitor.id)
    travel(1.second) { assert accepted?(answered(4)) }
    row = InAppView.find_by(in_app_campaign_id: @asking.id)
    assert_equal [0, true], [row.total, row.answered_at.present?]
    told = InAppStamps.user(@visitor.id)
    assert_not_equal before, told

    travel(2.seconds) { assert_not accepted?(answered(5)) }
    assert_equal [told, row.answered_at], [InAppStamps.user(@visitor.id), row.reload.answered_at]
  end

  test "a second answer from another device of the same person is refused too" do
    @asking = live_in_app_campaign(@project, content: asking)
    @visitor.update_columns(sdk_identifier: "ana")
    other = Visitor.create!(project: @project, device: devices(:android_device), sdk_identifier: "ana")
    assert accepted?(answered(4))
    @headers = sdk_headers_for(@project, other, platform: "android")
    assert_not accepted?(answered(2))
  end

  test "a comment needs an answer first, and a question that asks for one" do
    @asking = live_in_app_campaign(@project, content: asking)
    comment = ->(text = "Too slow") { answered(2, comment: text).merge(event_name: "in_app_commented") }
    assert_not accepted?(comment.call)
    assert accepted?(answered(2))
    assert accepted?(comment.call)

    silent = live_in_app_campaign(@project, content: asking(STARS.merge("comment" => nil)))
    assert accepted?(answered(2, campaign: silent))
    assert_not accepted?(answered(2, campaign: silent, comment: "Hi").merge(event_name: "in_app_commented"))
  end

  test "the single event endpoint refuses the two answer names, and they are not activity" do
    %w[in_app_answered in_app_commented].each do |name|
      post "#{SDK_PREFIX}/event/custom", params: { event_name: name }, headers: @headers, as: :json
      assert_response :bad_request
      assert_includes Grovs::Events::NOT_A_MESSAGE_SQL, "'#{name}'"
    end
  end

end
