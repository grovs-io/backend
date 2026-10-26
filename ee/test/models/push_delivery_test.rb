require "test_helper"

class PushDeliveryTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @campaign = PushCampaign.create!(project: projects(:one), name: "n", title: "t", body: "b", status: "sending",
                                     audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid])
    @row = PushDelivery.create!(push_campaign: @campaign, visitor: visitors(:ios_visitor), device_id: devices(:ios_device).id,
                                platform: "ios", status: "queued", rpush_notification_id: 4242)
  end

  test "delivered moves a queued row once and bumps the counter once" do
    assert PushDelivery.record_delivered!(4242)
    assert_not PushDelivery.record_delivered!(4242)
    assert_equal ["delivered", 1], [@row.reload.status, @campaign.reload.delivered]
  end

  test "failed stores the error and counts it under the APNs reason or the FCM code" do
    assert PushDelivery.record_failed!(4242, 410, "Unregistered")
    assert_equal %w[failed Unregistered], [@row.reload.status, @row.error]
    assert_equal({ "Unregistered" => 1 }, @campaign.reload.error_counts)
    other = PushDelivery.create!(push_campaign: @campaign, visitor: visitors(:android_visitor), device_id: devices(:android_device).id,
                                 platform: "android", status: "queued", rpush_notification_id: 4343)
    PushDelivery.record_failed!(4343, 404, "Client was not registered for your app. (UNREGISTERED)")
    assert_equal "404", other.reload.error
    assert_equal 2, @campaign.reload.failed
  end

  test "any APNs reason is kept as the error key; FCM sentences fall back to the code" do
    PushDelivery.record_failed!(4242, 413, "PayloadTooLarge")
    assert_equal({ "PayloadTooLarge" => 1 }, @campaign.reload.error_counts)
  end

  test "failed returns the row with its device so the caller can clear a dead token" do
    row = PushDelivery.record_failed!(4242, 410, "Unregistered")
    assert_equal devices(:ios_device).id, row.device_id
  end

  test "an unknown rpush id is ignored" do
    assert_not PushDelivery.record_delivered!(1)
    assert_not PushDelivery.record_failed!(1, 500, "x")
  end

  test "open is counted once per row" do
    assert PushDelivery.record_open!(@campaign, visitors(:ios_visitor))
    assert_not PushDelivery.record_open!(@campaign, visitors(:ios_visitor))
    assert @row.reload.opened_at
    assert_equal 1, @campaign.reload.opened
  end

  test "reconcile_queued! settles old queued rows from rpush's own flags" do
    app = Rpush::Apnsp8::App.create!(name: "t-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    ok = Rpush::Apnsp8::Notification.create!(app: app, device_token: "a" * 64, alert: "x", delivered: true)
    bad = Rpush::Apnsp8::Notification.create!(app: app, device_token: "b" * 64, alert: "x", failed: true, error_code: 410, error_description: "Unregistered")
    pending = Rpush::Apnsp8::Notification.create!(app: app, device_token: "c" * 64, alert: "x")
    v2 = Visitor.create!(project: projects(:one), device: devices(:android_device))
    v3 = Visitor.create!(project: projects(:one), device: devices(:ios_device))
    [[visitors(:android_visitor), ok.id], [v2, bad.id], [v3, pending.id]].each do |visitor, rid|
      PushDelivery.create!(push_campaign: @campaign, visitor: visitor, device_id: visitor.device_id, platform: "ios", status: "queued",
                           rpush_notification_id: rid, updated_at: 11.minutes.ago)
    end
    assert_equal 2, PushDelivery.reconcile_queued!(older_than: 10.minutes.ago)
    assert_equal %w[delivered failed queued], [ok, bad, pending].map { |n| PushDelivery.find_by(rpush_notification_id: n.id).status }
    assert_equal [1, 1], [@campaign.reload.delivered, @campaign.failed]
  ensure
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
  end

  test "reconcile clears a dead token like the batch path does" do
    app = Rpush::Apnsp8::App.create!(name: "rec-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b",
                                     connections: 1)
    token = "d" * 64
    devices(:ios_device).update_columns(push_token: token)
    dead = Rpush::Apnsp8::Notification.create!(app: app, device_token: token, alert: "x", failed: true, error_code: 410, error_description: "Unregistered")
    @row.update_columns(rpush_notification_id: dead.id, updated_at: 11.minutes.ago)

    assert_equal 1, PushDelivery.reconcile_queued!(older_than: 10.minutes.ago)
    assert_nil devices(:ios_device).reload.push_token
  ensure
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
  end

  test "a batch settles each campaign's queued rows with one bump per campaign, and a replay changes nothing" do
    other = PushCampaign.create!(project: projects(:one), name: "o", title: "t", body: "b", status: "sending",
                                 audience_type: "visitors", recipients: [visitors(:android_visitor).uuid])
    PushDelivery.create!(push_campaign: other, visitor: visitors(:android_visitor), device_id: devices(:android_device).id,
                         platform: "android", status: "queued", rpush_notification_id: 4343)

    bumps = 0
    original = PushCampaign.method(:bump!)
    counting = lambda do |*args, **kw|
      bumps += 1
      original.call(*args, **kw)
    end
    PushCampaign.stub(:bump!, counting) do
      assert_equal 2, PushDelivery.record_delivered_batch!([4242, 4343, 9999]).size
    end
    assert_equal 2, bumps
    assert_equal [1, 1], [@campaign.reload.delivered, other.reload.delivered]

    assert_empty PushDelivery.record_delivered_batch!([4242, 4343])
    assert_empty PushDelivery.record_failed_batch!([4242], 410, "Unregistered")
    assert_equal [1, 0], [@campaign.reload.delivered, @campaign.failed]
  end

  test "an FCM unregistered failure, as rpush reports it, clears the Android token" do
    device = devices(:android_device)
    device.update_columns(push_token: "fcm-dead")
    PushDelivery.create!(push_campaign: @campaign, visitor: visitors(:android_visitor), device_id: device.id,
                         platform: "android", status: "queued", rpush_notification_id: 5151)
    notification = Struct.new(:id, :error_code, :error_description, :device_token, :app_id)
                         .new(5151, 404, "Unable to deliver notification 5151, received error 404 (Client was not registered for your app. " \
                                         "(NOT_FOUND: Requested entity was not found.))", "fcm-dead", 1)

    PushOutcomes.failed(notification)

    assert_nil device.reload.push_token
  end

  test "removing an rpush app fails the deliveries whose pushes it deleted" do
    app = Rpush::Apnsp8::App.create!(name: "gone-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    push = Rpush::Apnsp8::Notification.create!(app: app, device_token: "a" * 64, alert: "x")
    @row.update_columns(rpush_notification_id: push.id)

    RpushService.remove_app(app)

    assert_equal %w[failed app_removed], [@row.reload.status, @row.error]
    assert_equal({ "app_removed" => 1 }, @campaign.reload.error_counts)
    assert_not Rpush::Notification.exists?(push.id)
  ensure
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
  end

  test "removing an app leaves a push mid-send alone; an orphan the deliverer raced in is purged later" do
    app = Rpush::Apnsp8::App.create!(name: "race-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    sending = Rpush::Apnsp8::Notification.create!(app: app, device_token: "a" * 64, alert: "x", processing: true)

    RpushService.remove_app(app)
    assert Rpush::Notification.exists?(sending.id), "a batch in flight settles it"

    orphan = Rpush::Apnsp8::Notification.new(device_token: "b" * 64, alert: "x", app_id: app.id).tap { |n| n.save!(validate: false) }
    @row.update_columns(rpush_notification_id: orphan.id)
    assert_equal 1, RpushService.purge_orphans
    assert_equal %w[failed app_removed], [@row.reload.status, @row.error]
    assert Rpush::Notification.exists?(sending.id), "a young processing orphan may still be sending"
  ensure
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
  end

  test "a stale push of a cancelled campaign is withdrawn, not released back to the queue" do
    app = Rpush::Apnsp8::App.create!(name: "stale-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t",
                                     bundle_id: "b", connections: 1)
    push = Rpush::Apnsp8::Notification.create!(app: app, device_token: "a" * 64, alert: "x", processing: true)
    push.update_columns(updated_at: 61.minutes.ago)
    @row.update_columns(rpush_notification_id: push.id)
    @campaign.update_columns(status: "cancelled", queued: 1)

    RpushStaleProcessing.release!

    assert_not Rpush::Notification.exists?(push.id)
    assert_equal "cancelled", @row.reload.status
    assert_equal [1, 0], [@campaign.reload.cancelled, @campaign.queued]
  ensure
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
  end

  test "BadDeviceToken from a sandbox app fails the push but keeps the token, which belongs to production" do
    sandbox = Rpush::Apnsp8::App.create!(name: "sbx-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b",
                                         connections: 1)
    live = Rpush::Apnsp8::App.create!(name: "sbx-prod", environment: "production", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b",
                                      connections: 1)
    token = "e" * 64
    devices(:ios_device).update_columns(push_token: token)
    sent = Rpush::Apnsp8::Notification.create!(app: sandbox, device_token: token, alert: "x")
    @row.update_columns(rpush_notification_id: sent.id)

    PushOutcomes.failed_batch([sent], 400, "BadDeviceToken")
    assert_equal %w[failed BadDeviceToken], [@row.reload.status, @row.error]
    assert_equal token, devices(:ios_device).reload.push_token

    sent.update_columns(app_id: live.id)
    @row.update_columns(status: "queued")
    PushOutcomes.failed_batch([sent.reload], 400, "BadDeviceToken")
    assert_nil devices(:ios_device).reload.push_token, "on production BadDeviceToken is a dead token"
  ensure
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
  end

  test "reconcile keeps a token a sandbox app called BadDeviceToken" do
    app = Rpush::Apnsp8::App.create!(name: "rsbx-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b",
                                     connections: 1)
    token = "f" * 64
    devices(:ios_device).update_columns(push_token: token)
    bad = Rpush::Apnsp8::Notification.create!(app: app, device_token: token, alert: "x", failed: true, error_code: 400, error_description: "BadDeviceToken")
    @row.update_columns(rpush_notification_id: bad.id, updated_at: 11.minutes.ago)

    assert_equal 1, PushDelivery.reconcile_queued!(older_than: 10.minutes.ago)
    assert_equal "failed", @row.reload.status
    assert_equal token, devices(:ios_device).reload.push_token
  ensure
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
  end

  test "the per-minute reconcile reads queued rows through their own index" do
    PushDelivery.transaction do
      PushDelivery.connection.execute("SET LOCAL enable_seqscan = off")
      plan = PushDelivery.where(status: "queued").where(updated_at: ...10.minutes.ago).order(:updated_at).limit(1000).explain.inspect
      assert_includes plan, "index_push_deliveries_queued_age"
    end
  end

  test "dead token detection" do
    assert PushDelivery.dead_token_error?(410, "Unregistered")
    assert PushDelivery.dead_token_error?(400, "BadDeviceToken")
    assert PushDelivery.dead_token_error?(404, "Client was not registered for your app. (UNREGISTERED)")
    assert PushDelivery.dead_token_error?(404, "Unable to deliver notification 7, received error 404 " \
                                               "(Client was not registered for your app. (NOT_FOUND: Requested entity was not found.))"),
           "the wording rpush actually stores"
    assert_not PushDelivery.dead_token_error?(400, "FCM failed to handle the JSON request. (Client was not registered)")
    assert_not PushDelivery.dead_token_error?(404, "BadPath"), "APNs 404 is a bad request path, not a dead token"
    assert_not PushDelivery.dead_token_error?(500, "InternalServerError")
  end

  test "a delivery writes no exposure: the freeze already counted everyone handed a variant" do
    REDIS.with { |conn| conn.del(BatchEventProcessorJob::REDIS_KEY) }
    @campaign.update!(conversion: { "event" => "checkout", "window_hours" => 24 }, variants: [{ "id" => "b", "title" => "B", "body" => "b" }])
    @row.reload.update!(status: "queued", variant: "b")
    assert PushDelivery.record_delivered!(4242)
    assert_equal [], REDIS.with { |conn| conn.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1) }
  end
end
