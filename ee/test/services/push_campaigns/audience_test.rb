require "test_helper"

class PushCampaigns::AudienceTest < ActiveSupport::TestCase
  include ConstStubHelper
  include ClickhouseTestHelper
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @ios = visitors(:ios_visitor)
    @android = visitors(:android_visitor)
    devices(:ios_device).update_columns(push_token: "tok-ios")
    devices(:android_device).update_columns(push_token: "tok-android")
  end

  def campaign(type, recipients)
    PushCampaign.create!(project: projects(:one), name: "n", title: "t", body: "b", audience_type: type, recipients: recipients)
  end

  def with_configured(ios: false, android: false, &block)
    RpushService.stub(:app_for_platform, lambda { |platform, _project|
      (platform == Grovs::Platforms::IOS && ios) || (platform == Grovs::Platforms::ANDROID && android) ? :app : nil
    }, &block)
  end

  test "visitor hashids become pending rows; unknown and foreign ones are not_found" do
    other = Visitor.create!(project: projects(:two), device: devices(:ios_device))
    c = campaign("visitors", [@ios.uuid, "nope", other.uuid])
    out = PushCampaigns::Audience.freeze!(c)
    assert_equal({ targeted: 1, no_channel: 0, not_found: 2, held: 0, waiting: 0 }, out)
    row = c.deliveries.find_by(visitor_id: @ios.id)
    assert_equal ["pending", devices(:ios_device).id, "ios", @ios.uuid], row.values_at(:status, :device_id, :platform, :recipient)
    assert_equal ["nope", other.uuid].sort, c.deliveries.where(status: "not_found").pluck(:recipient).sort
  end

  test "a device without a token or without a push platform is no_channel" do
    devices(:android_device).update_columns(push_token: nil)
    c = campaign("visitors", [@ios.uuid, @android.uuid])
    out = PushCampaigns::Audience.freeze!(c)
    assert_equal({ targeted: 2, no_channel: 1, not_found: 0, held: 0, waiting: 0 }, out)
    assert_equal "no_channel", c.deliveries.find_by(visitor_id: @android.id).status
  end

  test "identifiers resolve every device of the person, capped, unknown ones not_found" do
    c = campaign("identifiers", [@ios.sdk_identifier, "ghost"])
    out = PushCampaigns::Audience.freeze!(c)
    assert_equal({ targeted: 1, no_channel: 0, not_found: 1, held: 0, waiting: 0 }, out)
    assert_equal @ios.sdk_identifier, c.deliveries.find_by(visitor_id: @ios.id).recipient
    assert_equal "ghost", c.deliveries.find_by(status: "not_found").recipient
  end

  test "identifier fan-out is capped at IDENTIFIER_DEVICE_CAP devices" do
    with_const(PushCampaigns::Audience, :IDENTIFIER_DEVICE_CAP, 2) do
      3.times { Visitor.create!(project: projects(:one), device: devices(:ios_device), sdk_identifier: "shared") }
      c = campaign("identifiers", ["shared"])
      assert_equal 2, PushCampaigns::Audience.freeze!(c)[:targeted]
    end
  end

  test "an uppercase uuid matches once and is not also not_found" do
    c = campaign("visitors", [@ios.uuid.upcase])
    assert_equal({ targeted: 1, no_channel: 0, not_found: 0, held: 0, waiting: 0 }, PushCampaigns::Audience.freeze!(c))
    expected = { devices: 1, no_channel: 0, not_found: 0, no_app: 1, reachable: 0,
                 platforms: { "ios" => { devices: 1, configured: false }, "android" => { devices: 0, configured: false } } }
    assert_equal expected, PushCampaigns::Audience.estimate(c)
  end

  test "re-running is idempotent" do
    c = campaign("visitors", [@ios.uuid, "nope"])
    PushCampaigns::Audience.freeze!(c)
    PushCampaigns::Audience.freeze!(c)
    assert_equal 2, c.deliveries.count
  end

  test "due_at is stamped on every row" do
    at = 1.hour.from_now.change(usec: 0)
    c = campaign("visitors", [@ios.uuid])
    PushCampaigns::Audience.freeze!(c, due_at: at)
    assert_equal at, c.deliveries.first.due_at
  end

  test "a segment audience pages ids out of ClickHouse in sort-key order and freezes the effective visitors once" do
    seg = Segment.create!(project: projects(:one), name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    c = PushCampaign.create!(project: projects(:one), name: "n", title: "t", body: "b", audience_type: "segment", segment: seg, recipients: [])
    c.update!(c.segment_snapshot_attrs)
    manifest = Segments::Results::Manifest.new(result_id: "a" * 32, project_id: projects(:one).id, definition_hash: seg.definition_hash,
                                               list_generation: nil, persons: 2, devices: 2, rows: 3, incomplete: true)
    pages = [[{ "visitor_id" => 1, "eff_visitor_id" => @ios.id }, { "visitor_id" => 2, "eff_visitor_id" => @ios.id }],
             [{ "visitor_id" => 3, "eff_visitor_id" => @android.id }], []]
    seen_sql = []
    Segments::Results.stub(:for, manifest) do
      Segments::Runner.stub(:read, ->(sql, **) { seen_sql.push(sql) && pages.shift }) do
        assert_equal({ targeted: 2, no_channel: 0, not_found: 0, held: 0, waiting: 0 }, PushCampaigns::Audience.freeze!(c))
      end
    end
    assert_match(/visitor_id > 2 ORDER BY visitor_id/, seen_sql[1], "keyset on the sort key, not on eff_visitor_id")
    c.reload
    assert_equal [2, 2, true], [c.audience_persons, c.audience_devices, c.audience_incomplete]
    c.update!(status: "evaluating")
    Segments::Results.stub(:for, manifest) do
      Segments::Runner.stub(:read, ->(*) { [] }) { PushCampaigns::Evaluate.call(c) }
    end
    assert_equal 2, c.reload.audience_devices, "Evaluate keeps the manifest's device count for a segment"
    assert_equal %w[segment segment], c.deliveries.pluck(:recipient)
  end

  test "a segment audience is evaluated in the campaigns permit lane" do
    seg = Segment.create!(project: projects(:one), name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    c = PushCampaign.create!(project: projects(:one), name: "n", title: "t", body: "b", audience_type: "segment", segment: seg, recipients: [])
    c.update!(c.segment_snapshot_attrs)
    lanes = []
    REDIS.with { |r| r.del("segments:result_key:#{projects(:one).id}:#{seg.definition_hash}::#{Date.current.iso8601}") }
    Segments::Runner.stub(:materialize, ->(_pid, _sql, **kw) { lanes << kw[:lane] }) do
      Segments::Results.stub(:totals, { persons: 0, devices: 0, rows: 0 }) do
        Segments::Runner.stub(:read, ->(*) { [] }) { PushCampaigns::Audience.freeze!(c) }
      end
    end
    assert_equal [:campaigns], lanes
  end

  test "estimate for a segment audience reports persons, devices and the platform breakdown" do
    seg = Segment.create!(project: projects(:one), name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    c = PushCampaign.create!(project: projects(:one), name: "n", title: "t", body: "b", audience_type: "segment", segment: seg, recipients: [])
    stub = { persons: 5, devices: 7, ios_devices: 4, android_devices: 3, approximate: false, incomplete: false }
    Segments.stub(:estimate_with_platforms, stub) do
      with_configured(ios: true) do
        expected = { devices: 7, no_channel: 0, not_found: 0, persons: 5, incomplete: false, no_app: 3, reachable: 4,
                     platforms: { "ios" => { devices: 4, configured: true }, "android" => { devices: 3, configured: false } } }
        assert_equal expected, PushCampaigns::Audience.estimate(c)
      end
    end
  end

  test "a too-heavy platform split reports null reach fields, not an error" do
    seg = Segment.create!(project: projects(:one), name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    c = PushCampaign.create!(project: projects(:one), name: "n", title: "t", body: "b", audience_type: "segment", segment: seg, recipients: [])
    stub = { persons: 5, devices: 7, ios_devices: nil, android_devices: nil, approximate: false, incomplete: false }
    Segments.stub(:estimate_with_platforms, stub) do
      with_configured(ios: true) do
        out = PushCampaigns::Audience.estimate(c)
        assert_equal({ devices: 7, no_channel: 0, not_found: 0, persons: 5, incomplete: false, no_app: nil, reachable: nil,
                       platforms: { "ios" => { devices: nil, configured: true }, "android" => { devices: nil, configured: false } } }, out)
      end
    end
  end

  test "an ios-only configured project excludes android from reachable and counts it in no_app" do
    c = campaign("visitors", [@ios.uuid, @android.uuid])
    with_configured(ios: true) do
      out = PushCampaigns::Audience.estimate(c)
      assert_equal({ devices: 2, no_channel: 0, no_app: 1, reachable: 1 }, out.slice(:devices, :no_channel, :no_app, :reachable))
      assert_equal({ "ios" => { devices: 1, configured: true }, "android" => { devices: 1, configured: false } }, out[:platforms])
    end
  end

  test "nothing configured means reachable is 0" do
    c = campaign("visitors", [@ios.uuid, @android.uuid])
    with_configured do
      out = PushCampaigns::Audience.estimate(c)
      assert_equal 0, out[:reachable]
      assert_equal 2, out[:no_app]
    end
  end

  test "both platforms configured means reachable equals devices minus no_channel" do
    c = campaign("visitors", [@ios.uuid, @android.uuid])
    with_configured(ios: true, android: true) do
      out = PushCampaigns::Audience.estimate(c)
      assert_equal out[:devices] - out[:no_channel], out[:reachable]
      assert_equal 0, out[:no_app]
    end
  end

  test "identifiers also split reach by configured platform" do
    c = campaign("identifiers", [@ios.sdk_identifier, @android.sdk_identifier])
    with_configured(ios: true) do
      out = PushCampaigns::Audience.estimate(c)
      assert_equal({ no_app: 1, reachable: 1 }, out.slice(:no_app, :reachable))
    end
  end

  test "local time gives every device its own due_at from its timezone, clamped to now when already past" do
    at = Time.utc(2026, 10, 1, 9, 0)
    devices(:ios_device).update_columns(timezone: "America/New_York")
    devices(:android_device).update_columns(timezone: nil)
    c = campaign("visitors", [@ios.uuid, @android.uuid])
    c.update!(scheduled_at: at, local_time: true, timezone: "UTC")
    travel_to(at - 14.hours) { PushCampaigns::Audience.freeze!(c, due_at: at) }
    assert_equal Time.utc(2026, 10, 1, 13, 0), c.deliveries.find_by(visitor_id: @ios.id).due_at, "09:00 New York is 13:00 UTC"
    assert_equal at, c.deliveries.find_by(visitor_id: @android.id).due_at, "no timezone falls back to the campaign zone"
    devices(:ios_device).update_columns(timezone: "Asia/Tokyo") # 09:00 Tokyo = 00:00 UTC, already past at 10:00 UTC
    travel_to(at + 1.hour) do
      c2 = campaign("visitors", [@ios.uuid])
      c2.update!(scheduled_at: at, local_time: true, timezone: "UTC")
      PushCampaigns::Audience.freeze!(c2, due_at: at)
      assert_in_delta Time.current, c2.deliveries.first.due_at, 2
    end
  end

  test "estimate counts without writing rows" do
    c = campaign("identifiers", [@ios.sdk_identifier, "ghost"])
    out = PushCampaigns::Audience.estimate(c)
    assert_equal({ devices: 1, no_channel: 0, not_found: 1 }, out.slice(:devices, :no_channel, :not_found))
    devices(:android_device).update_columns(push_token: nil)
    c = campaign("visitors", [@ios.uuid, @android.uuid, "nope"])
    out = PushCampaigns::Audience.estimate(c)
    assert_equal({ devices: 2, no_channel: 1, not_found: 1 }, out.slice(:devices, :no_channel, :not_found))
    assert_equal 0, PushDelivery.count
  end

  def ch_profile(visitor, platform:)
    { project_id: projects(:one).id, visitor_id: visitor, sdk_identifier: "", properties: {},
      first_seen: "2026-09-01 00:00:00.000", last_seen: "2026-09-20 00:00:00.000", platform: platform }
  end

  def ch_checkout(visitor)
    { project_id: projects(:one).id, visitor_id: visitor, event_type: "custom", event_name: "checkout", created_at: "2026-09-20 00:00:00.000" }
  end

  test "a live segment estimate returns the platform breakdown and no_app" do
    skip_unless_clickhouse!
    insert_ch_user_profiles([ch_profile(501, platform: "ios"), ch_profile(502, platform: "android")])
    insert_ch_events([ch_checkout(501), ch_checkout(502)])
    definition = { "version" => 1, "operator" => "or", "groups" => [{ "operator" => "and", "conditions" => [
      { "type" => "event", "event_name" => "checkout", "window" => { "last_days" => 30 } }
    ] }] }
    seg = Segment.create!(project: projects(:one), name: "S", definition: definition)
    c = PushCampaign.create!(project: projects(:one), name: "n", title: "t", body: "b", audience_type: "segment", segment: seg, recipients: [])

    with_configured(ios: true) do
      travel_to(Time.utc(2026, 9, 24)) do
        out = PushCampaigns::Audience.estimate(c)
        assert_equal 2, out[:devices]
        assert_equal({ "ios" => { devices: 1, configured: true }, "android" => { devices: 1, configured: false } }, out[:platforms])
        assert_equal 1, out[:no_app]
        assert_equal 1, out[:reachable]
      end
    end
  end

  def queued(name)
    REDIS.with { |conn| conn.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1) }.map { |raw| JSON.parse(raw) }.select { |e| e["event_name"] == name }
  end

  test "an experiment holds the control by bucket, hands the rest a variant, and keeps a share waiting" do
    REDIS.with { |conn| conn.del(BatchEventProcessorJob::REDIS_KEY) }
    c = campaign("visitors", [@ios.uuid, @android.uuid])
    c.update!(variants: [{ "id" => "b", "title" => "B", "body" => "b" }], test_share: 50)
    ios_bucket = Experiments::Bucket.of(c.hashid, @ios.id)
    c.update_columns(control_group: ios_bucket + 1)
    out = PushCampaigns::Audience.freeze!(c)
    ios = c.deliveries.find_by(visitor_id: @ios.id)
    assert_equal ["held", nil], [ios.status, ios.variant]
    android = c.deliveries.find_by(visitor_id: @android.id)
    if Experiments::Bucket.of(c.hashid, @android.id) < c.control_group
      assert_equal "held", android.status
      assert_equal({ targeted: 0, no_channel: 0, not_found: 0, held: 2, waiting: 0 }, out)
    else
      expected = Experiments::Split.group(Experiments::Bucket.of(c.hashid, @android.id), control: c.control_group, variants: 2)
      waits = Experiments::Bucket.of("#{c.hashid}:test", @android.id) >= 50
      assert_equal [waits ? "waiting" : "pending", expected], [android.status, android.variant]
      assert_equal({ targeted: 1, no_channel: 0, not_found: 0, held: 1, waiting: waits ? 1 : 0 }, out)
    end
    held = queued("push_held")
    assert_equal out[:held], held.size
    assert_equal({ "campaign_id" => c.hashid, "scope" => "campaign" }, held.first["data"])
    assert_equal devices(:ios_device).id, held.find { |e| e["device_id"] == devices(:ios_device).id }["device_id"]
  end

  test "the project-wide control group is held under its own scope, and a person without a channel is never held" do
    REDIS.with { |conn| conn.del(BatchEventProcessorJob::REDIS_KEY) }
    InAppSetting.create!(project: projects(:one), control_group: 20)
    devices(:android_device).update_columns(push_token: nil)
    c = campaign("visitors", [@ios.uuid, @android.uuid])
    out = PushCampaigns::Audience.freeze!(c)
    assert_equal "no_channel", c.deliveries.find_by(visitor_id: @android.id).status
    if Experiments::Bucket.of(projects(:one).hashid, @ios.id) < 20
      assert_equal({ targeted: 1, no_channel: 1, not_found: 0, held: 1, waiting: 0 }, out)
      assert_equal [{ "campaign_id" => c.hashid, "scope" => "project" }], queued("push_held").map { |e| e["data"] }
    else
      assert_equal({ targeted: 2, no_channel: 1, not_found: 0, held: 0, waiting: 0 }, out)
      assert_equal "a", c.deliveries.find_by(visitor_id: @ios.id).variant
    end
  end

  test "intent to treat: everyone handed a variant is exposed at the freeze like the control, the waiting share when the winner goes" do
    REDIS.with { |conn| conn.del(BatchEventProcessorJob::REDIS_KEY) }
    people = Array.new(40) { Visitor.create!(project: projects(:one), device: devices(:ios_device)) }
    c = campaign("visitors", people.map(&:uuid))
    c.update!(variants: [{ "id" => "b", "title" => "B", "body" => "b" }], test_share: 50, control_group: 20)
    PushCampaigns::Audience.freeze!(c)
    sent = c.deliveries.where(status: "pending")
    assert_operator sent.count, :positive?
    exposed = queued("push_delivered")
    assert_equal sent.pluck(:variant).sort, exposed.map { |e| e["data"]["variant"] }.sort
    assert_equal [c.hashid], exposed.map { |e| e["data"]["campaign_id"] }.uniq
    assert_equal queued("push_held").map { |e| e["created_at"] }.uniq, exposed.map { |e| e["created_at"] }.uniq

    waiting = c.deliveries.where(status: "waiting").count
    c.update_columns(status: "sent", waiting: waiting)
    assert c.send_winner!("b")
    b = ->(events) { events.count { |e| e["data"]["variant"] == "b" } }
    after = queued("push_delivered")
    assert_equal [exposed.size + waiting, b.call(exposed) + waiting], [after.size, b.call(after)]
  end

  test "a local-time send exposes each person when their row is due, not at the early freeze" do
    REDIS.with { |conn| conn.del(BatchEventProcessorJob::REDIS_KEY) }
    at = Time.utc(2026, 10, 1, 9, 0)
    devices(:ios_device).update_columns(timezone: "America/New_York")
    people = Array.new(20) { Visitor.create!(project: projects(:one), device: devices(:ios_device)) }
    c = campaign("visitors", people.map(&:uuid))
    c.update!(scheduled_at: at, local_time: true, timezone: "UTC", variants: [{ "id" => "b", "title" => "B", "body" => "b" }], control_group: 20)
    travel_to(at - 14.hours) { PushCampaigns::Audience.freeze!(c, due_at: at) }
    stamps = %w[push_delivered push_held].flat_map { |name| queued(name) }.map { |e| Time.zone.parse(e["created_at"]) }.uniq
    assert_equal [Time.utc(2026, 10, 1, 13, 0)], stamps, "09:00 New York is 13:00 UTC"
  end

  test "the winner is sent even when its exposure cannot be written" do
    c = campaign("visitors", [@ios.uuid, @android.uuid])
    c.update!(variants: [{ "id" => "b", "title" => "B", "body" => "b" }], test_share: 10)
    PushCampaigns::Audience.freeze!(c)
    c.deliveries.update_all(status: "waiting")
    c.update_columns(status: "sent", waiting: 2)
    Experiments::Held.stub(:push, ->(*) { raise Redis::CannotConnectError, "down" }) { assert c.send_winner!("b") }
    assert_equal [["pending", "b"]], c.deliveries.distinct.pluck(:status, :variant)
    assert_equal "sending", c.reload.status
  end
end
