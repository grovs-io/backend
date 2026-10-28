require "test_helper"
require "sidekiq/testing"
require_relative "../../../test/integration/auth_test_helper"

class PushCampaignsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include ConstStubHelper
  include ClickhouseTestHelper
  fixtures :instances, :users, :instance_roles, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    entitle!(@project.instance)
    @admin = doorkeeper_headers_for(users(:admin_user))
    @member = doorkeeper_headers_for(users(:member_user))
    devices(:ios_device).update_columns(push_token: "tok")
  end

  def base = "#{API_PREFIX}/projects/#{@project.id}/push_campaigns"
  def estimate_base = "#{base}/estimate"

  def create!(headers: @admin, **extra)
    post base, params: { name: "Launch", title: "Hi", body: "There", audience: { type: "visitors", recipients: [visitors(:ios_visitor).uuid] } }.merge(extra),
               headers: headers, as: :json
    JSON.parse(response.body)
  end

  # No rpush app exists in fixtures, so ios/android are always unconfigured here.
  def reach(ios: 0, android: 0)
    { "no_app" => ios + android, "reachable" => 0,
      "platforms" => { "ios" => { "devices" => ios, "configured" => false }, "android" => { "devices" => android, "configured" => false } } }
  end

  test "admin creates a draft and it comes back with an empty report" do
    body = create!
    assert_response :created
    c = body["push_campaign"]
    assert_equal %w[draft visitors], [c["status"], c["audience"]["type"]]
    assert_equal 0, c["report"]["targeted"]
    assert_equal 1, AuditEvent.where(action: "push_campaign.created").count
  end

  test "members draft, send and cancel campaigns like admins" do
    id = create!(headers: @member)["push_campaign"]["id"]
    assert_response :created
    patch "#{base}/#{id}", params: { title: "Edited" }, headers: @member, as: :json
    assert_response :ok
    get base, headers: @member
    assert_response :ok
    post "#{base}/#{id}/send", params: { scheduled_at: 2.days.from_now.iso8601 }, headers: @member, as: :json
    assert_response :accepted
    post "#{base}/#{id}/cancel", headers: @member, as: :json
    assert_response :ok
    assert_equal "cancelled", PushCampaign.find_by_hashid(id).status
  end

  test "validation errors are 422 with the message" do
    create!(title: "")
    assert_response :unprocessable_entity
    assert_match(/Title/, JSON.parse(response.body)["error"])
    create!(audience: { type: "segment", segment_id: "x" })
    assert_response :unprocessable_entity
    create!(data: "nope")
    assert_response :unprocessable_entity
  end

  test "the list is slim and show carries the recipients" do
    id = create!["push_campaign"]["id"]
    get base, headers: @admin
    row = JSON.parse(response.body)["push_campaigns"][0]
    assert_equal 1, row["audience"]["recipients_count"]
    assert_nil row["audience"]["recipients"]
    get "#{base}/#{id}", headers: @admin
    assert_equal [visitors(:ios_visitor).uuid], JSON.parse(response.body)["push_campaign"]["audience"]["recipients"]
  end

  test "send moves to evaluating and enqueues the evaluate job; a second send is 409" do
    id = create!["push_campaign"]["id"]
    Sidekiq::Testing.fake! do
      PushCampaignEvaluateJob.clear
      post "#{base}/#{id}/send", headers: @admin, as: :json
      assert_response :accepted
      assert_equal 1, PushCampaignEvaluateJob.jobs.size
    end
    assert_equal "evaluating", JSON.parse(response.body)["push_campaign"]["status"]
    post "#{base}/#{id}/send", headers: @admin, as: :json
    assert_response :conflict
  end

  test "send with scheduled_at schedules; a past or too-close local time is 422 and leaves the draft" do
    id = create!["push_campaign"]["id"]
    post "#{base}/#{id}/send", params: { scheduled_at: 1.hour.ago.iso8601 }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    post "#{base}/#{id}/send", params: { scheduled_at: 2.hours.from_now.iso8601, local_time: true }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    post "#{base}/#{id}/send", params: { local_time: true }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    ["not a date", "2026-13-45T99:00:00Z"].each do |bad|
      post "#{base}/#{id}/send", params: { scheduled_at: bad }, headers: @admin, as: :json
      assert_response :unprocessable_entity
      assert_equal "scheduled_at must be an ISO 8601 time", JSON.parse(response.body)["error"]
    end
    assert_equal "draft", PushCampaign.find_by_hashid(id).status
    post "#{base}/#{id}/send", params: { scheduled_at: 20.hours.from_now.iso8601, local_time: true, timezone: "Europe/Bucharest" }, headers: @admin, as: :json
    assert_response :accepted
    c = JSON.parse(response.body)["push_campaign"]
    assert_equal ["scheduled", true, "Europe/Bucharest"], [c["status"], c["local_time"], c["timezone"]]
    post "#{base}/#{id}/cancel", headers: @admin, as: :json
    assert_response :ok
  end

  test "a segment audience is created by segment id, estimated through Segments, snapshotted on send and untouched by a re-send" do
    seg = Segment.create!(project: @project, name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    body = create!(audience: { type: "segment", segment_id: seg.hashid })
    assert_response :created
    id = body["push_campaign"]["id"]
    assert_equal seg.hashid, body["push_campaign"]["audience"]["segment_id"]
    Segments.stub(:estimate_with_platforms, { persons: 3, devices: 4, ios_devices: 3, android_devices: 1, approximate: false, incomplete: false }) do
      post "#{base}/#{id}/estimate", headers: @admin, as: :json
      assert_equal({ "devices" => 4, "no_channel" => 0, "not_found" => 0, "persons" => 3, "incomplete" => false }.merge(reach(ios: 3, android: 1)),
                   JSON.parse(response.body))
    end
    first_hash = seg.definition_hash
    Sidekiq::Testing.fake! { post "#{base}/#{id}/send", params: { scheduled_at: 1.hour.from_now.iso8601 }, headers: @admin, as: :json }
    assert_response :accepted
    seg.update!(definition: PushCampaignFixtures::SEGMENT_DEFINITION.merge("groups" => [{ "operator" => "and", "conditions" => [
      { "type" => "event", "any" => true, "window" => { "last_days" => 7 } }
    ] }]))
    post "#{base}/#{id}/send", headers: @admin, as: :json
    assert_response :conflict
    assert_equal first_hash, PushCampaign.find_by_hashid(id).segment_definition_hash, "a refused re-send must not touch the snapshot"
    create!(audience: { type: "segment", segment_id: "nope" })
    assert_response :unprocessable_entity
  end

  test "a too-heavy platform split renders nulls, not an error, and satisfies the contract" do
    seg = Segment.create!(project: @project, name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    id = create!(audience: { type: "segment", segment_id: seg.hashid })["push_campaign"]["id"]
    stub = { persons: 3, devices: 4, ios_devices: nil, android_devices: nil, approximate: false, incomplete: false }
    Segments.stub(:estimate_with_platforms, stub) do
      post "#{base}/#{id}/estimate", headers: @admin, as: :json
    end
    assert_response :ok
    assert_equal({ "devices" => 4, "no_channel" => 0, "not_found" => 0, "persons" => 3, "incomplete" => false,
                   "no_app" => nil, "reachable" => nil,
                   "platforms" => { "ios" => { "devices" => nil, "configured" => false },
                                    "android" => { "devices" => nil, "configured" => false } } },
                 JSON.parse(response.body))
  end

  test "an image can be uploaded with the campaign and removed again while it is a draft" do
    file = Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/push.png"), "image/png")
    post base, params: { name: "Img", title: "Hi", body: "There", image: file, "audience[type]" => "visitors",
                         "audience[recipients][]" => visitors(:ios_visitor).uuid }, headers: @admin
    assert_response :created
    c = JSON.parse(response.body)["push_campaign"]
    assert_match(%r{/rails/active_storage/blobs/}, c["image"])
    assert_nil c["image_url"]
    delete "#{base}/#{c['id']}/image", headers: @admin
    assert_response :ok
    assert_nil JSON.parse(response.body)["push_campaign"]["image"]
    bad = Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/push.txt"), "text/plain")
    patch "#{base}/#{c['id']}", params: { image: bad }, headers: @admin
    assert_response :unprocessable_entity
    good = Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/push.png"), "image/png")
    patch "#{base}/#{c['id']}", params: { image: good, title: "" }, headers: @admin
    assert_response :unprocessable_entity
    assert_not PushCampaign.find_by_hashid(c["id"]).image.attached?, "a refused update must not keep the image"
    PushCampaign.find_by_hashid(c["id"]).update!(status: "sent")
    delete "#{base}/#{c['id']}/image", headers: @admin
    assert_response :conflict
  end

  test "estimate translates segment errors into coded responses" do
    seg = Segment.create!(project: @project, name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    id = create!(audience: { type: "segment", segment_id: seg.hashid })["push_campaign"]["id"]
    Segments.stub(:estimate_with_platforms, ->(*) { raise Segments::Busy }) { post "#{base}/#{id}/estimate", headers: @admin, as: :json }
    assert_response :too_many_requests
    Segments.stub(:estimate_with_platforms, ->(*) { raise Clickhouse::Unavailable, "segments" }) { post "#{base}/#{id}/estimate", headers: @admin, as: :json }
    assert_response :service_unavailable
    Segments.stub(:estimate_with_platforms, ->(*) { raise Segments::InvalidDefinition, "bad" }) { post "#{base}/#{id}/estimate", headers: @admin, as: :json }
    assert_response :unprocessable_entity
    assert_equal "invalid_segment", JSON.parse(response.body)["error_code"]
    Segments.stub(:estimate_with_platforms, ->(*) { raise Analytics::QueryTooHeavy }) { post "#{base}/#{id}/estimate", headers: @admin, as: :json }
    assert_equal "query_too_heavy", JSON.parse(response.body)["error_code"]
  end

  test "cancel while sending drops pending rows and reports them; evaluating is 409" do
    id = create!["push_campaign"]["id"]
    c = PushCampaign.find_by_hashid(id)
    c.update!(status: "sending")
    PushCampaigns::Audience.freeze!(c)
    post "#{base}/#{id}/cancel", headers: @admin, as: :json
    assert_response :ok
    assert_equal ["cancelled", 1], [JSON.parse(response.body)["push_campaign"]["status"], JSON.parse(response.body)["push_campaign"]["report"]["cancelled"]]
    c.reload.update!(status: "evaluating")
    post "#{base}/#{id}/cancel", headers: @admin, as: :json
    assert_response :conflict
  end

  test "end to end: send, run the jobs inline, report shows queued and deliveries list it" do
    id = create!["push_campaign"]["id"]
    apns = Rpush::Apnsp8::App.create!(name: "t-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    Sidekiq::Testing.inline! do
      RpushService.stub(:app_for_platform, apns) { post "#{base}/#{id}/send", headers: @admin, as: :json }
    end
    get "#{base}/#{id}", headers: @admin
    c = JSON.parse(response.body)["push_campaign"]
    assert_equal "sent", c["status"]
    assert_equal({ "targeted" => 1, "queued" => 1 }, c["report"].slice("targeted", "queued"))
    get "#{base}/#{id}/deliveries", params: { status: "queued" }, headers: @admin
    d = JSON.parse(response.body)
    assert_equal 1, d["deliveries"].size
    assert_equal visitors(:ios_visitor).uuid, d["deliveries"][0]["visitor"]["uuid"]
    assert_equal visitors(:ios_visitor).uuid, d["deliveries"][0]["recipient"]
    assert_nil d["next_after"]
  ensure
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
  end

  test "cancel only from draft; patch only while draft" do
    id = create!["push_campaign"]["id"]
    patch "#{base}/#{id}", params: { title: "New" }, headers: @admin, as: :json
    assert_response :ok
    post "#{base}/#{id}/cancel", headers: @admin, as: :json
    assert_response :ok
    assert_equal "cancelled", JSON.parse(response.body)["push_campaign"]["status"]
    patch "#{base}/#{id}", params: { title: "Again" }, headers: @admin, as: :json
    assert_response :conflict
    post "#{base}/#{id}/cancel", headers: @admin, as: :json
    assert_response :conflict
  end

  test "index reports truncation past the list limit" do
    with_const(Api::V1::PushCampaignsController, :LIST_LIMIT, 1) do
      create!
      create!
      get base, headers: @admin
      body = JSON.parse(response.body)
      assert_equal [1, true], [body["push_campaigns"].size, body["truncated"]]
    end
  end

  test "index pages newest first with an after cursor" do
    first = create!["push_campaign"]["id"]
    second = create!["push_campaign"]["id"]
    third = create!["push_campaign"]["id"]
    get base, params: { limit: 2 }, headers: @admin
    body = JSON.parse(response.body)
    assert_equal [third, second], body["push_campaigns"].map { |c| c["id"] }
    assert_equal [true, second], [body["truncated"], body["next_after"]]
    get base, params: { limit: 2, after: body["next_after"] }, headers: @admin
    body = JSON.parse(response.body)
    assert_equal [first], body["push_campaigns"].map { |c| c["id"] }
    assert_equal [false, nil], [body["truncated"], body["next_after"]]
  end

  test "index with a bad cursor or limit is 422" do
    get base, params: { after: "not-a-hashid!" }, headers: @admin
    assert_response :unprocessable_entity
    get base, params: { limit: "many" }, headers: @admin
    assert_response :unprocessable_entity
  end

  test "deliveries with a non-integer cursor is 422" do
    id = create!["push_campaign"]["id"]
    get "#{base}/#{id}/deliveries", params: { after: "abc" }, headers: @admin
    assert_response :unprocessable_entity
  end

  test "a patch racing a send gets 409, not 500" do
    id = create!["push_campaign"]["id"]
    original = PushCampaign.instance_method(:save)
    PushCampaign.define_method(:save) { |*| raise ActiveRecord::StaleObjectError.new(self, "update") }
    begin
      patch "#{base}/#{id}", params: { title: "New" }, headers: @admin, as: :json
    ensure
      PushCampaign.define_method(:save, original)
    end
    assert_response :conflict
  end

  test "estimate for a list audience counts devices without writing rows" do
    id = create!(audience: { type: "identifiers", recipients: [visitors(:ios_visitor).sdk_identifier, "ghost"] })["push_campaign"]["id"]
    post "#{base}/#{id}/estimate", headers: @admin, as: :json
    assert_response :ok
    assert_equal({ "devices" => 1, "no_channel" => 0, "not_found" => 1 }.merge(reach(ios: 1)), JSON.parse(response.body))
    assert_equal 0, PushDelivery.count
  end

  test "estimate_audience computes visitors, identifiers and segment reach with no saved campaign" do
    assert_no_difference "PushCampaign.count" do
      post estimate_base, params: { audience: { type: "visitors", recipients: [visitors(:ios_visitor).uuid] } }, headers: @admin, as: :json
      assert_response :ok
      assert_equal({ "devices" => 1, "no_channel" => 0, "not_found" => 0 }.merge(reach(ios: 1)), JSON.parse(response.body))

      post estimate_base, params: { audience: { type: "identifiers", recipients: [visitors(:ios_visitor).sdk_identifier, "ghost"] } },
                           headers: @admin, as: :json
      assert_response :ok
      assert_equal({ "devices" => 1, "no_channel" => 0, "not_found" => 1 }.merge(reach(ios: 1)), JSON.parse(response.body))

      seg = Segment.create!(project: @project, name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
      Segments.stub(:estimate_with_platforms, { persons: 3, devices: 4, ios_devices: 3, android_devices: 1, approximate: false, incomplete: false }) do
        post estimate_base, params: { audience: { type: "segment", segment_id: seg.hashid } }, headers: @admin, as: :json
      end
      assert_response :ok
      assert_equal({ "devices" => 4, "no_channel" => 0, "not_found" => 0, "persons" => 3, "incomplete" => false }.merge(reach(ios: 3, android: 1)),
                   JSON.parse(response.body))
    end
  end

  test "estimate_audience ignores link_id, data, name, title, body and image" do
    file = Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/push.png"), "image/png")
    assert_no_difference ["PushCampaign.count", "ActiveStorage::Attachment.count"] do
      post estimate_base, params: { "audience[type]" => "visitors", "audience[recipients][]" => visitors(:ios_visitor).uuid,
                                    link_id: 999_999_999, data: "nope", name: "x", title: "y", body: "z", image: file },
                           headers: @admin
    end
    assert_response :ok
    assert_equal({ "devices" => 1, "no_channel" => 0, "not_found" => 0 }.merge(reach(ios: 1)), JSON.parse(response.body))
  end

  test "estimate_audience invalid audience is 422 with the exact error body create gives" do
    archived = Segment.create!(project: @project, name: "S2", definition: PushCampaignFixtures::SEGMENT_DEFINITION, archived: true)
    bad_audiences = [
      { type: "visitors", recipients: [] },
      { type: "identifiers", recipients: (1..PushCampaign::MAX_RECIPIENTS + 1).map(&:to_s) },
      { type: "segment", segment_id: "nope" },
      { type: "segment", segment_id: archived.hashid }
    ]

    bad_audiences.each do |audience|
      created = create!(audience: audience)
      assert_response :unprocessable_entity

      post estimate_base, params: { audience: audience }, headers: @admin, as: :json
      assert_response :unprocessable_entity
      assert_equal created["error"], JSON.parse(response.body)["error"]
    end
  end

  test "estimate_audience rejects a segment from another project" do
    other = Segment.create!(project: projects(:two), name: "Other", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    post estimate_base, params: { audience: { type: "segment", segment_id: other.hashid } }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_match(/Segment not found/, JSON.parse(response.body)["error"])
  end

  test "estimate_audience is open to members and requires auth" do
    post estimate_base, params: { audience: { type: "visitors", recipients: [visitors(:ios_visitor).uuid] } }, headers: @member, as: :json
    assert_response :ok

    post estimate_base, params: { audience: { type: "visitors", recipients: [visitors(:ios_visitor).uuid] } }, headers: api_headers, as: :json
    assert_response :unauthorized
  end

  test "a disabled plan gate answers 404" do
    original = Instance.instance_method(:push_campaigns_enabled?)
    Instance.define_method(:push_campaigns_enabled?) { false }
    begin
      get base, headers: @admin
    ensure
      Instance.define_method(:push_campaigns_enabled?, original)
    end
    assert_response :not_found
  end

  test "index filters by status and is scoped to the project" do
    create!
    other = PushCampaign.create!(project: projects(:two), name: "x", title: "t", body: "b", audience_type: "visitors", recipients: ["a"])
    get base, params: { status: "draft" }, headers: @admin
    ids = JSON.parse(response.body)["push_campaigns"].map { |c| c["id"] }
    assert_not_includes ids, other.hashid
    assert_equal 1, ids.size
    get "#{base}/#{other.hashid}", headers: @admin
    assert_response :not_found
  end

  B = { "id" => "b", "title" => "Hey", "body" => "Look" }.freeze

  test "a test share keeps rows waiting, the winner goes to them once, and the payload carries the variant" do
    devices(:android_device).update_columns(push_token: "tok2")
    body = create!(variants: [B], test_share: 10, audience: { type: "visitors", recipients: [visitors(:ios_visitor).uuid, visitors(:android_visitor).uuid] })
    id = body["push_campaign"]["id"]
    assert_equal [[B], 10, nil], body["push_campaign"].values_at("variants", "test_share", "control_group")
    c = PushCampaign.find_by_hashid(id)
    apns = Rpush::Apnsp8::App.create!(name: "t-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    fcm = Rpush::Fcm::App.create!(name: "t-and", environment: "development", firebase_project_id: "p", json_key: "{}", connections: 1)
    apps = ->(platform, _) { platform == "ios" ? apns : fcm }
    # Everyone waits: nobody's test bucket is under 0.
    Experiments::Bucket.stub(:of, ->(salt, id) { salt.end_with?(":test") ? 99 : Digest::MD5.hexdigest("#{salt}:#{id}")[0, 8].to_i(16) % 100 }) do
      Sidekiq::Testing.inline! { RpushService.stub(:app_for_platform, apps) { post "#{base}/#{id}/send", headers: @admin, as: :json } }
    end
    get "#{base}/#{id}", headers: @admin
    report = JSON.parse(response.body)["push_campaign"]["report"]
    assert_equal ["sent", 2, 0, 2], [JSON.parse(response.body)["push_campaign"]["status"], report["targeted"], report["queued"], report["waiting"]]
    assert_equal %w[waiting waiting], c.deliveries.pluck(:status)

    post "#{base}/#{id}/send_winner", params: { variant: "z" }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    Sidekiq::Testing.inline! { RpushService.stub(:app_for_platform, apps) { post "#{base}/#{id}/send_winner", params: { variant: "b" }, headers: @admin, as: :json } }
    assert_response :accepted
    assert_equal 1, AuditEvent.where(action: "push_campaign.winner_sent").count
    get "#{base}/#{id}", headers: @admin
    report = JSON.parse(response.body)["push_campaign"]["report"]
    assert_equal ["sent", 2, 0], [JSON.parse(response.body)["push_campaign"]["status"], report["queued"], report["waiting"]]
    assert_equal %w[b b], c.deliveries.pluck(:variant)
    assert_equal [{ "title" => "Hey", "body" => "Look" }], Rpush::Apnsp8::Notification.all.map(&:alert).uniq
    assert_equal [{ "title" => "Hey", "body" => "Look" }], Rpush::Fcm::Notification.all.map { |n| n.notification.except("tag") }.uniq
    assert_equal c.deliveries.where(platform: "android").map { |d| "grovs-#{d.id}" }.sort, Rpush::Fcm::Notification.all.map { |n| n.notification["tag"] }.sort
    post "#{base}/#{id}/send_winner", params: { variant: "b" }, headers: @admin, as: :json
    assert_response :conflict
  ensure
    Rpush::Notification.delete_all
    Rpush::App.delete_all
  end

  test "a manual winner is claimed in the request; the rows, exposures and sends move in a job, and the timer cannot pick another" do
    id = create!(variants: [B], test_share: 10, winner_after_minutes: 30)["push_campaign"]["id"]
    c = PushCampaign.find_by_hashid(id)
    c.update_columns(status: "sent", waiting: 1, winner_due_at: 1.hour.from_now)
    PushDelivery.create!(push_campaign: c, visitor: visitors(:ios_visitor), device_id: devices(:ios_device).id, platform: "ios", status: "waiting")
    Sidekiq::Testing.fake! do
      [PushWinnerJob, PushCampaignDeliverJob].each(&:clear)
      post "#{base}/#{id}/send_winner", params: { variant: "b" }, headers: @admin, as: :json
      assert_response :accepted
      assert_equal [["waiting", nil]], c.deliveries.pluck(:status, :variant), "nothing heavy runs in the request"
      assert_equal [[c.id]], PushWinnerJob.jobs.map { |job| job["args"] }
      post "#{base}/#{id}/send_winner", params: { variant: "a" }, headers: @admin, as: :json
      assert_response :conflict

      Experiments::Winner.stub(:pick, ->(*) { flunk "a chosen winner is not judged again" }) { PushWinnerJob.drain }
    end
    assert_equal [["pending", "b"]], c.deliveries.pluck(:status, :variant)
    assert_equal ["sending", "b", 0], [c.reload.status, c.winner, c.waiting]
    assert_operator PushCampaignDeliverJob.jobs.size, :positive?
    assert_equal [{ "variant" => "b" }], AuditEvent.where(action: "push_campaign.winner_sent").map { |e| e.changes_data["after"] }
  end

  test "cancel from sent drops the waiting rows" do
    id = create!(variants: [B], test_share: 10)["push_campaign"]["id"]
    c = PushCampaign.find_by_hashid(id)
    c.update!(status: "sent", waiting: 1)
    PushDelivery.create!(push_campaign: c, visitor: visitors(:ios_visitor), device_id: devices(:ios_device).id, platform: "ios", status: "waiting")
    post "#{base}/#{id}/cancel", headers: @admin, as: :json
    assert_response :ok
    assert_equal ["cancelled", 1, 0], JSON.parse(response.body)["push_campaign"].then { |p| [p["status"], p["report"]["cancelled"], p["report"]["waiting"]] }
    assert_equal ["cancelled"], c.deliveries.pluck(:status)
  end

  test "the experiment of a push campaign is read from ClickHouse; a plain campaign has none" do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    id = create!(control_group: 10, conversion: { event: "checkout", window_hours: 24 })["push_campaign"]["id"]
    c = PushCampaign.find_by_hashid(id)
    c.update!(status: "sent", started_at: Time.utc(2026, 9, 20, 9))
    a = (1..).lazy.select { |v| Experiments::Bucket.of(c.hashid, v) >= 10 }.first(2)
    held = (1..).lazy.select { |v| Experiments::Bucket.of(c.hashid, v) < 10 }.first(1)
    at = Time.utc(2026, 9, 20, 10)
    row = lambda do |name, visitor, when_, **props|
      { project_id: @project.id, event_type: "custom", event_name: name, visitor_id: visitor, platform: "ios",
        created_at: when_.strftime("%Y-%m-%d %H:%M:%S.%L"), properties: props }
    end
    insert_ch_events([row.call("push_delivered", a[0], at, campaign_id: c.hashid, variant: "a"),
                      row.call("push_open", a[0], at + 1.minute, campaign_id: c.hashid),
                      row.call("checkout", a[0], at + 2.hours), row.call("push_delivered", a[1], at, campaign_id: c.hashid, variant: "a"),
                      row.call("push_held", held[0], at, campaign_id: c.hashid, scope: "campaign")])
    get "#{base}/#{id}/experiment", params: { from: "2026-09-20", to: "2026-09-21" }, headers: @admin
    assert_response :ok
    out = JSON.parse(response.body)["experiment"]
    rows = out["groups"].index_by { |g| g["id"] }
    assert_equal [2, 1, 1, 0.5], rows["a"].values_at("exposed", "clicked", "converted", "conversion_rate")
    assert_equal [1, nil, 0, 0.0], rows["control"].values_at("exposed", "clicked", "converted", "conversion_rate")
    assert_equal [nil, 1], out.values_at("lift", "added_conversions")

    plain = create!["push_campaign"]["id"]
    get "#{base}/#{plain}/experiment", headers: @admin
    assert_response :unprocessable_entity
  end

  test "after the winner went out, people are counted under the variant they received; the project control is this campaign's" do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    id = create!(control_group: 10, variants: [B], test_share: 20)["push_campaign"]["id"]
    c = PushCampaign.find_by_hashid(id)
    c.update!(status: "sent", started_at: 400.days.ago)
    other = create!(control_group: 10)["push_campaign"]["id"]
    at = 2.days.ago
    row = lambda do |name, visitor, **props|
      { project_id: @project.id, event_type: "custom", event_name: name, visitor_id: visitor, platform: "ios",
        created_at: at.utc.strftime("%Y-%m-%d %H:%M:%S.%L"), properties: props }
    end
    a_person = (1..).lazy.select { |v| Experiments::Split.group(Experiments::Bucket.of(c.hashid, v), control: 10, variants: 2) == "a" }.first(2)
    insert_ch_events([row.call("push_delivered", a_person[0], campaign_id: c.hashid, variant: "b"), row.call("push_open", a_person[0], campaign_id: c.hashid),
                      row.call("push_delivered", a_person[1], campaign_id: c.hashid, variant: "a"),
                      row.call("push_held", 500, campaign_id: c.hashid, scope: "project"),
                      row.call("push_held", 501, campaign_id: other, scope: "project"), row.call("push_held", 502, campaign_id: other, scope: "campaign")])
    InAppSetting.create!(project: @project, control_group: 5)
    get "#{base}/#{id}/experiment", headers: @admin
    assert_response :ok, "the default range is clamped for an old campaign"
    rows = JSON.parse(response.body)["experiment"]["groups"].index_by { |g| g["id"] }
    assert_equal [1, 0], rows["a"].values_at("exposed", "clicked")
    assert_equal [1, 1], rows["b"].values_at("exposed", "clicked")
    assert_equal 1, rows["project_control"]["exposed"]
    assert_equal 0, rows["control"]["exposed"]
  end

  test "a broken campaign does not stop the winner tick for the others" do
    id = create!(variants: [B], test_share: 10, winner_after_minutes: 30)["push_campaign"]["id"]
    c = PushCampaign.find_by_hashid(id)
    c.update_columns(status: "sent", waiting: 1, winner_due_at: 1.minute.ago)
    PushDelivery.create!(push_campaign: c, visitor: visitors(:ios_visitor), device_id: devices(:ios_device).id, platform: "ios", status: "waiting")
    broken = Minitest::Mock.new
    Experiments::Winner.stub(:pick, ->(campaign) { campaign.id == c.id ? "b" : raise("boom") }) do
      other = PushCampaign.find_by_hashid(create!(variants: [B], test_share: 10, winner_after_minutes: 30)["push_campaign"]["id"])
      other.update_columns(status: "sent", waiting: 1, winner_due_at: 1.minute.ago, created_at: 1.hour.ago)
      Sidekiq::Testing.fake! { Experiments::Winner.due }
      assert_equal 2, PushWinnerJob.jobs.size, "one job per due campaign"
      Sidekiq::Testing.fake! { PushWinnerJob.drain }
    end
    assert_equal ["sending", "b", 0], [c.reload.status, c.winner, c.waiting]
    broken.verify
  end

  test "malformed variants are refused, not a crash" do
    create!(variants: [1])
    assert_response :unprocessable_entity
    create!(variants: [{ "id" => "b", "title" => "x", "body" => "y", "extra" => 1 }])
    assert_response :unprocessable_entity
    create!(variants: [{ "id" => "b", "title" => "x" * 256, "body" => "y" }])
    assert_response :unprocessable_entity
  end

  test "the timer picks the best rate only once every variant reached enough people; ties go to A" do
    c = PushCampaign.find_by_hashid(create!(variants: [B], test_share: 10, winner_after_minutes: 30)["push_campaign"]["id"])
    report = lambda do |exposed_a, rate_a, exposed_b, rate_b|
      groups = [{ "id" => "a", "exposed" => exposed_a, "click_rate" => rate_a }, { "id" => "b", "exposed" => exposed_b, "click_rate" => rate_b }]
      ->(*, **) { { "groups" => groups } }
    end
    n = Experiments::Report::MIN_PEOPLE
    Experiments::Report.stub(:push, report.call(n, 0.1, n, 0.2)) { assert_equal "b", Experiments::Winner.pick(c) }
    Experiments::Report.stub(:push, report.call(n, 0.1, n - 1, 0.9)) { assert_equal "a", Experiments::Winner.pick(c) }
    Experiments::Report.stub(:push, report.call(n, 0.2, n, 0.2)) { assert_equal "a", Experiments::Winner.pick(c) }
  end

  test "a timer sends the winner by itself: A when the test share is too small to judge" do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    devices(:android_device).update_columns(push_token: "tok2")
    body = create!(variants: [B], test_share: 10, winner_after_minutes: 30, winner_by: "opens",
                   audience: { type: "visitors", recipients: [visitors(:ios_visitor).uuid, visitors(:android_visitor).uuid] })
    id = body["push_campaign"]["id"]
    assert_equal [30, "opens", nil], body["push_campaign"].values_at("winner_after_minutes", "winner_by", "winner_due_at")
    c = PushCampaign.find_by_hashid(id)
    apns = Rpush::Apnsp8::App.create!(name: "t-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    fcm = Rpush::Fcm::App.create!(name: "t-and", environment: "development", firebase_project_id: "p", json_key: "{}", connections: 1)
    apps = ->(platform, _) { platform == "ios" ? apns : fcm }
    Experiments::Bucket.stub(:of, ->(salt, id) { salt.end_with?(":test") ? 99 : Digest::MD5.hexdigest("#{salt}:#{id}")[0, 8].to_i(16) % 100 }) do
      Sidekiq::Testing.inline! { RpushService.stub(:app_for_platform, apps) { post "#{base}/#{id}/send", headers: @admin, as: :json } }
    end
    c.reload
    assert_equal ["sent", 2], [c.status, c.waiting]
    assert_in_delta c.started_at + 30.minutes, c.winner_due_at, 1
    at = Time.current
    row = lambda do |name, visitor, **props|
      { project_id: @project.id, event_type: "custom", event_name: name, visitor_id: visitor, platform: "ios",
        created_at: at.utc.strftime("%Y-%m-%d %H:%M:%S.%L"), properties: props }
    end
    insert_ch_events([row.call("push_delivered", 1, campaign_id: c.hashid, variant: "a"), row.call("push_delivered", 2, campaign_id: c.hashid, variant: "b"),
                      row.call("push_open", 2, campaign_id: c.hashid)])

    Sidekiq::Testing.inline! { RpushService.stub(:app_for_platform, apps) { Experiments::Winner.due } }
    assert_equal ["sent", 2], [c.reload.status, c.waiting], "not due yet"

    travel 31.minutes do
      Sidekiq::Testing.inline! { RpushService.stub(:app_for_platform, apps) { Experiments::Winner.due } }
    end
    c.reload
    assert_equal ["sent", 0, "a", nil], [c.status, c.waiting, c.winner, c.winner_due_at], "one person a side decides nothing"
    assert_equal %w[a a], c.deliveries.pluck(:variant)
    logged = AuditEvent.where(action: "push_campaign.winner_sent").map { |e| e.changes_data["after"] }
    assert_equal [{ "variant" => "a", "by" => "opens", "automatic" => true }], logged

    truncate_clickhouse_tables
    assert_equal "a", Experiments::Winner.pick(c)
    c.update!(conversion: { "event" => "checkout", "window_hours" => 24 }, winner_by: "conversions")
    assert_equal "a", Experiments::Winner.pick(c)
  ensure
    Rpush::Notification.delete_all
    Rpush::App.delete_all
  end

  test "a multipart create with an image keeps the experiment" do
    image = fixture_file_upload("push.png", "image/png")
    post base, params: { name: "Img", title: "Hi", body: "There", image: image, control_group: "10", test_share: "20",
                         conversion: { event: "checkout", window_hours: 24 }.to_json, variants: [B].to_json,
                         audience: { type: "visitors", recipients: [visitors(:ios_visitor).uuid] } }, headers: @admin
    assert_response :created
    c = JSON.parse(response.body)["push_campaign"]
    assert_equal [10, 20, { "event" => "checkout", "window_hours" => 24 }, [B]], c.values_at("control_group", "test_share", "conversion", "variants")
  end

  test "a test share cannot go with local-time delivery" do
    id = create!(variants: [B], test_share: 10)["push_campaign"]["id"]
    post "#{base}/#{id}/send", params: { scheduled_at: 2.days.from_now.iso8601, local_time: true, timezone: "Europe/Bucharest" }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_match(/local-time/, JSON.parse(response.body)["error"])
  end

  test "the timer needs a test share, and judging by conversions needs a goal" do
    create!(variants: [B], winner_after_minutes: 30)
    assert_response :unprocessable_entity
    create!(variants: [B], test_share: 10, winner_after_minutes: 45)
    assert_response :unprocessable_entity
    create!(variants: [B], test_share: 10, winner_after_minutes: 60, winner_by: "conversions")
    assert_response :unprocessable_entity
  end

  test "the purge lets nobody wait for a winner past retention, and an API push is never held by the project control" do
    id = create!(variants: [B], test_share: 10)["push_campaign"]["id"]
    c = PushCampaign.find_by_hashid(id)
    c.update_columns(status: "sent", waiting: 3, winner_due_at: 1.hour.from_now, finished_at: 40.days.ago)
    PushCampaignPurgeJob.new.perform
    assert_equal [0, nil], [c.reload.waiting, c.winner_due_at]

    InAppSetting.create!(project: @project, control_group: 20)
    api = PushCampaign.create!(project: @project, name: "n", title: "t", body: "b", source: "api", audience_type: "visitors",
                               recipients: [visitors(:ios_visitor).uuid])
    PushCampaigns::Audience.freeze!(api)
    assert_equal "pending", api.deliveries.sole.status
  end
end
