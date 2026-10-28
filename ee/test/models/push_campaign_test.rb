require "test_helper"

class PushCampaignTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :users, :visitors, :devices, :domains, :redirect_configs, :links

  def build(**attrs)
    PushCampaign.new({ project: projects(:one), name: "Launch", title: "Hi", body: "There",
                       audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid] }.merge(attrs))
  end

  test "a valid list campaign saves as a draft" do
    c = build
    assert c.save, c.errors.full_messages.join(", ")
    assert_equal "draft", c.status
    assert_equal "dashboard", c.source
  end

  test "payload and audience validations" do
    assert_not build(title: "").valid?
    assert_not build(image_url: "http://x/y.png").valid?
    assert build(image_url: "https://x/y.png").valid?
    assert_not build(image_url: "https://x/y.png\njavascript:alert(1)").valid?, "the whole value must be one https URL"
    assert_not build(image_url: "https://x/y .png").valid?
    assert_not build(audience_type: "people").valid?
    assert_not build(recipients: "abc").valid?
    assert_not build(recipients: Array.new(PushCampaign::MAX_RECIPIENTS + 1) { "x" }).valid?
    assert_not build(data: { "k" => "v" * PushCampaign::MAX_DATA_BYTES }).valid?
    assert_not build(audience_type: "segment", recipients: []).valid?, "a segment audience needs a segment"
  end

  test "data can't use keys that break the APNs or FCM payload" do
    %w[aps APS from notification message_type headers __rpush_mdm__ __rpush_content_available__ google.c.a.e gcm.n.e].each do |key|
      assert_not build(data: { key => "x" }).valid?, key
    end
    assert build(data: { "promo" => "spring", "fromage" => "brie", "screen" => "home" }).valid?
  end

  test "valid_audience? checks only the audience fields, ignoring missing title/body" do
    c = PushCampaign.new(project: projects(:one), audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid])
    assert c.valid_audience?
    assert_not c.valid?, "title/body are still required for a real save"
    assert_not PushCampaign.new(project: projects(:one), audience_type: "visitors", recipients: []).valid_audience?
    assert_not PushCampaign.new(project: projects(:one), audience_type: "bogus", recipients: []).valid_audience?

    seg = Segment.create!(project: projects(:one), name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    assert PushCampaign.new(project: projects(:one), audience_type: "segment", recipients: [], segment: seg).valid_audience?
    other = Segment.create!(project: projects(:two), name: "O", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    assert_not PushCampaign.new(project: projects(:one), audience_type: "segment", recipients: [], segment: other).valid_audience?
  end

  test "a segment audience needs an active segment of the same project and no recipients" do
    seg = Segment.create!(project: projects(:one), name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    assert build(audience_type: "segment", recipients: [], segment: seg).valid?
    assert_not build(audience_type: "segment", recipients: ["x"], segment: seg).valid?
    seg.update!(archived: true)
    assert_not build(audience_type: "segment", recipients: [], segment: seg).valid?
    other = Segment.create!(project: projects(:two), name: "O", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    assert_not build(audience_type: "segment", recipients: [], segment: other).valid?
  end

  test "segment_snapshot_attrs carries the definition, hash and list generation" do
    seg = Segment.create!(project: projects(:one), name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    c = build(audience_type: "segment", recipients: [], segment: seg)
    assert_equal({ segment_definition: seg.definition, segment_definition_hash: seg.definition_hash, segment_list_generation: nil },
                 c.segment_snapshot_attrs)
  end

  test "schedule validations" do
    assert_not build(status: "scheduled", scheduled_at: 1.hour.ago).valid?
    assert_not build(status: "scheduled", scheduled_at: 31.days.from_now).valid?
    assert build(status: "scheduled", scheduled_at: 1.hour.from_now).valid?
    assert_not build(status: "scheduled", scheduled_at: 1.hour.from_now, local_time: true).valid?, "local time needs a 14h lead"
    assert build(status: "scheduled", scheduled_at: 15.hours.from_now, local_time: true).valid?
    assert_not build(status: "scheduled", scheduled_at: 20.hours.from_now, local_time: true, timezone: "Pacific/Honolulu").valid?,
               "a zone behind UTC needs 14h plus its offset"
    assert build(status: "scheduled", scheduled_at: 6.hours.from_now, local_time: true, timezone: "Asia/Tokyo").valid?
    assert_not build(local_time: true).valid?, "local_time needs scheduled_at"
    assert_not build(timezone: "Mars/Olympus").valid?
    assert_equal "UTC", build.tap(&:valid?).timezone
  end

  test "cancel! withdraws queued pushes rpush has not picked up, and keeps the ones it is sending" do
    c = build(status: "sending", queued: 3)
    c.save!
    app = Rpush::Apnsp8::App.create!(name: "t-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    waiting = Rpush::Apnsp8::Notification.create!(app: app, device_token: "a" * 64, alert: "x")
    sending = Rpush::Apnsp8::Notification.create!(app: app, device_token: "b" * 64, alert: "x", processing: true)
    sent = Rpush::Apnsp8::Notification.create!(app: app, device_token: "c" * 64, alert: "x", delivered: true)
    [waiting, sending, sent].each_with_index do |n, i|
      v = Visitor.create!(project: projects(:one), device: devices(:ios_device))
      PushDelivery.create!(push_campaign: c, visitor: v, device_id: devices(:ios_device).id, platform: "ios", status: "queued",
                           recipient: "q#{i}", rpush_notification_id: n.id)
    end

    assert c.cancel!

    c.reload
    assert_equal [1, 2], [c.cancelled, c.queued]
    assert_nil Rpush::Notification.find_by(id: waiting.id)
    assert Rpush::Notification.exists?(sending.id)
    assert_equal %w[cancelled queued queued], c.deliveries.order(:id).pluck(:status)
  ensure
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
  end

  test "a campaign whose segment was archived after it was sent can still be cancelled" do
    seg = Segment.create!(project: projects(:one), name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    c = build(audience_type: "segment", segment: seg, recipients: [], status: "sending")
    c.save!
    seg.update_columns(archived: true)

    assert c.reload.cancel!
    assert_equal "cancelled", c.reload.status
    assert_not build(audience_type: "segment", segment: seg, recipients: []).valid?, "a new campaign can't pick it"
  end

  test "cancel! drops pending and claimed rows, keeps queued ones, and refuses while evaluating" do
    c = build(status: "sending")
    c.save!
    %w[pending pending claimed queued].each_with_index do |st, i|
      v = Visitor.create!(project: projects(:one), device: devices(:ios_device))
      PushDelivery.create!(push_campaign: c, visitor: v, device_id: devices(:ios_device).id, platform: "ios", status: st, recipient: "r#{i}")
    end
    assert c.cancel!
    c.reload
    assert_equal ["cancelled", 3], [c.status, c.cancelled]
    assert_equal %w[cancelled cancelled cancelled queued], c.deliveries.order(:id).pluck(:status)
    e = build(status: "evaluating")
    e.save!
    assert_not e.cancel!
  end

  test "recount! rebuilds drifted counters from the delivery rows" do
    c = build(status: "sent", queued: 99, delivered: 1, failed: 0, cancelled: 7, error_counts: { "stale" => 3 })
    c.save!
    [["delivered", nil], ["delivered", nil], ["failed", "Unregistered"], ["failed", "no_token"], ["cancelled", nil]].each_with_index do |(st, err), i|
      v = Visitor.create!(project: projects(:one), device: devices(:ios_device))
      PushDelivery.create!(push_campaign: c, visitor: v, device_id: devices(:ios_device).id, platform: "ios", status: st, error: err,
                           recipient: "r#{i}", opened_at: (Time.current if i.zero?))
    end

    assert_equal %i[queued delivered failed cancelled opened error_counts].sort, c.recount!.sort
    c.reload
    assert_equal [3, 2, 2, 1, 1], [c.queued, c.delivered, c.failed, c.cancelled, c.opened], "no_token never reached rpush"
    assert_equal({ "Unregistered" => 1, "no_token" => 1 }, c.error_counts)
    assert_empty c.recount!, "already exact"
  end

  test "an uploaded image must be an image under the size cap, and wins only when image_url is blank" do
    c = build
    c.image.attach(io: File.open(Rails.root.join("test/fixtures/files/push.txt")), filename: "push.txt", content_type: "text/plain")
    assert_not c.valid?
    c = build
    c.image.attach(io: File.open(Rails.root.join("test/fixtures/files/push.png")), filename: "push.png", content_type: "image/png")
    assert c.valid?, c.errors.full_messages.join(", ")
    c.save!
    assert_match(%r{\Ahttps://.+/rails/active_storage/blobs/}, c.image_resource)
    c.image_url = "https://cdn/x.png"
    assert_equal "https://cdn/x.png", c.image_resource
    c = build
    c.image.attach(io: StringIO.new("x" * (PushCampaign::IMAGE_MAX_BYTES + 1)), filename: "big.png", content_type: "image/png")
    assert_not c.valid?
  end

  test "a WebP upload is refused: iOS notifications only show PNG, JPEG and GIF" do
    c = build
    c.image.attach(io: StringIO.new("RIFF\x1A\x00\x00\x00WEBPVP8 ".b + "\x00".b * 16), filename: "push.webp", content_type: "image/webp")
    assert_equal "image/webp", c.image.blob.content_type
    assert_not c.valid?
    assert_includes c.errors[:image], "must be a PNG, JPEG or GIF"
  end

  test "the link must belong to the project (links hang off domains)" do
    assert build(link: links(:basic_link)).valid?
    assert_not build(link: links(:second_link)).valid?
  end

  test "transition! moves only from an allowed status, under lock" do
    c = build
    c.save!
    assert c.transition!(from: %w[draft], to: "evaluating", started_at: Time.current)
    assert_equal "evaluating", c.reload.status
    assert_not c.transition!(from: %w[draft], to: "cancelled")
    assert_equal "evaluating", c.reload.status
  end

  test "bump! adds counters and merges error counts atomically" do
    c = build
    c.save!
    PushCampaign.bump!(c.id, queued: 3, failed: 2, errors: { "no_app" => 2 })
    PushCampaign.bump!(c.id, failed: 1, errors: { "no_app" => 1 })
    c.reload
    assert_equal [3, 3], [c.queued, c.failed]
    assert_equal({ "no_app" => 3 }, c.error_counts)
    PushCampaign.bump!(c.id, failed: 2, errors: { "no_app" => 1, "no_token" => 1 })
    assert_equal({ "no_app" => 4, "no_token" => 1 }, c.reload.error_counts, "two error keys in one slice must not double-assign the column")
    assert_equal 3, c.report[:queued]
  end

  test "hot counters spread over shards and read back as the row plus every shard" do
    c = build(queued: 5, error_counts: { "no_app" => 1 })
    c.save!
    PushCampaignCounter.stub(:shard, 1) { PushCampaign.bump!(c.id, delivered: 2, opened: 1) }
    PushCampaignCounter.stub(:shard, 7) { PushCampaign.bump!(c.id, delivered: 3, failed: 1, errors: { "no_app" => 2, "BadPath" => 1 }) }
    c.reload
    assert_equal PushCampaignCounter::SHARDS, c.counter_shards.size, "created with the campaign, so bumps never insert"
    assert_equal [2, 3], c.counter_shards.map(&:delivered).select(&:positive?).sort
    assert_equal [5, 5, 1, 1], [c.queued, c.delivered, c.failed, c.opened]
    assert_equal({ "no_app" => 3, "BadPath" => 1 }, c.error_counts)
    assert_equal 5, c.report[:delivered]
    assert_equal({ "no_app" => 1 }, c.read_attribute(:error_counts), "the row itself is untouched")
  end

  test "recount! folds shards into the row" do
    c = build(status: "sent")
    c.save!
    PushCampaignCounter.stub(:shard, 3) { PushCampaign.bump!(c.id, delivered: 4) }
    PushDelivery.create!(push_campaign: c, visitor: visitors(:ios_visitor), device_id: devices(:ios_device).id, platform: "ios", status: "delivered")
    assert_includes c.recount!, :delivered
    c.reload
    assert_equal [1, 0], [c.delivered, c.counter_shards.sum(&:delivered)]
  end

  test "recount! mid-send keeps rows still queued in rpush as queued" do
    c = build(status: "sending")
    c.save!
    PushDelivery.create!(push_campaign: c, visitor: visitors(:ios_visitor), device_id: devices(:ios_device).id, platform: "ios", status: "queued")
    c.recount!
    assert_equal 1, c.reload.queued
  end

  test "cancel! records withdrawn pushes as cancelled and no longer queued" do
    c = build(status: "sending")
    c.save!
    PushCampaign.bump!(c.id, queued: 2)
    app = Rpush::Apnsp8::App.create!(name: "t-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    n = Rpush::Apnsp8::Notification.create!(app: app, device_token: "a" * 64, alert: "x")
    PushDelivery.create!(push_campaign: c, visitor: visitors(:ios_visitor), device_id: devices(:ios_device).id, platform: "ios", status: "queued",
                         rpush_notification_id: n.id)
    assert c.cancel!
    c.reload
    assert_equal [1, 1], [c.queued, c.cancelled]
  ensure
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
  end

  test "deleting a campaign deletes its deliveries" do
    c = build
    c.save!
    PushDelivery.create!(push_campaign: c, visitor: visitors(:ios_visitor), device_id: devices(:ios_device).id, platform: "ios", status: "pending")
    c.destroy!
    assert_equal 0, PushDelivery.where(push_campaign_id: c.id).count
  end

  test "an experiment is shaped: control percent, goal, variants with title and body, a test share only with variants" do
    c = PushCampaign.new(project: projects(:one), name: "n", title: "t", body: "b", audience_type: "visitors", recipients: ["x"])
    assert c.valid?
    c.control_group = 60
    assert_not c.valid?
    c.control_group = 10
    c.test_share = 20
    assert_not c.valid?
    c.variants = [{ "id" => "b", "title" => "B", "body" => "" }]
    assert_not c.valid?
    c.variants = [{ "id" => "b", "title" => "B", "body" => "bb" }, { "id" => "c", "title" => "C", "body" => "cc" }]
    c.conversion = { "event" => "checkout", "window_hours" => 72 }
    assert c.valid?, c.errors.full_messages.join(", ")
    assert_equal %w[a b c], c.variant_ids
    assert_equal ["B", "bb", "t", "b"], [c.title_for("b"), c.body_for("b"), c.title_for("a"), c.body_for(nil)]
    c.variants = [{ "id" => "b", "title" => "x" * 255, "body" => "y" * 1000 }]
    c.data = { "pad" => "z" * 3500 }
    assert_not c.valid?
    assert_match(/variant B/, c.errors.full_messages.join)
  end
end
