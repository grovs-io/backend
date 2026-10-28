require "test_helper"

class PushCampaigns::PayloadTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :redirect_configs, :links

  setup do
    @campaign = PushCampaign.create!(project: projects(:one), name: "n", title: "Hello", body: "World", sound: "default",
                                     image_url: "https://cdn/x.png", data: { "k" => "v", "grovs_link" => "spoof" },
                                     audience_type: "visitors", recipients: ["abc"], link: links(:basic_link))
    @apns_app = Rpush::Apnsp8::App.new(name: "t", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b")
    @fcm_app = Rpush::Fcm::App.new(name: "f", firebase_project_id: "p", json_key: "{}")
  end

  test "data carries campaign id, link and image, and customer keys never override grovs keys" do
    d = PushCampaigns::Payload.new(@campaign).data
    assert_equal @campaign.hashid, d["grovs_campaign_id"]
    assert_equal links(:basic_link).access_path, d["grovs_link"]
    assert_equal "https://cdn/x.png", d["grovs_image"]
    assert_equal "v", d["k"]
  end

  test "APNs notification: alert, sound, data, mutable content when an image is set" do
    n = PushCampaigns::Payload.new(@campaign).build("ios", @apns_app, "tok")
    assert_kind_of Rpush::Apnsp8::Notification, n
    assert_equal({ "title" => "Hello", "body" => "World" }, n.alert)
    assert_equal "default", n.sound
    assert_equal "tok", n.device_token
    assert_equal 1, n.as_json["aps"]["mutable-content"], "rpush stores the flag inside data, not the column"
    assert_equal @campaign.hashid, n.data["grovs_campaign_id"]
  end

  test "FCM notification: title, body, image, sound and data" do
    n = PushCampaigns::Payload.new(@campaign).build("android", @fcm_app, "tok")
    assert_kind_of Rpush::Fcm::Notification, n
    assert_equal({ "title" => "Hello", "body" => "World", "image" => "https://cdn/x.png" }, n.notification)
    assert_equal "default", n.sound
    assert_equal links(:basic_link).access_path, n.data["grovs_link"]
  end

  test "FCM data values are strings; APNs keeps the JSON" do
    @campaign.update!(data: { "n" => 1, "flag" => true, "nested" => { "a" => 1 } })
    fcm = PushCampaigns::Payload.new(@campaign).build("android", @fcm_app, "tok")
    assert_equal({ "n" => "1", "flag" => "true", "nested" => "{\"a\":1}" }, fcm.data.slice("n", "flag", "nested"))
    apns = PushCampaigns::Payload.new(@campaign).build("ios", @apns_app, "tok")
    assert_equal 1, apns.data["n"]
  end

  test "no image means no mutable content and no image key" do
    @campaign.update!(image_url: nil)
    assert_nil PushCampaigns::Payload.new(@campaign).build("ios", @apns_app, "tok").as_json["aps"]["mutable-content"]
    assert_nil PushCampaigns::Payload.new(@campaign).build("android", @fcm_app, "tok").notification["image"]
  end

  test "an uploaded image feeds the payload when no image_url is set" do
    @campaign.update!(image_url: nil)
    @campaign.image.attach(io: File.open(Rails.root.join("test/fixtures/files/push.png")), filename: "push.png", content_type: "image/png")
    n = PushCampaigns::Payload.new(@campaign).build("ios", @apns_app, "tok")
    assert_match(%r{/rails/active_storage/blobs/}, n.data["grovs_image"])
    assert_equal 1, n.as_json["aps"]["mutable-content"]
  end

  test "a delivery's APNs push carries its collapse id under rpush's headers key" do
    n = PushCampaigns::Payload.new(@campaign).build("ios", @apns_app, "tok", nil, 42)
    assert_equal({ "apns-collapse-id" => "grovs-42" }, n.data["headers"])
    assert_nil PushCampaigns::Payload.new(@campaign).build("ios", @apns_app, "tok").data["headers"]
  end

  test "a delivery's FCM push carries the same id as its Android tag" do
    n = PushCampaigns::Payload.new(@campaign).build("android", @fcm_app, "tok", nil, 42)
    assert_equal "grovs-42", n.as_json.dig("message", "android", "notification", "tag")
  end

  test "a campaign saved before headers was refused still cannot set APNs headers" do
    @campaign.update_columns(data: { "headers" => { "apns-topic" => "com.other.app" } })
    assert_nil PushCampaigns::Payload.new(@campaign).build("ios", @apns_app, "tok").data["headers"]
    assert_equal({ "apns-collapse-id" => "grovs-1" }, PushCampaigns::Payload.new(@campaign).build("ios", @apns_app, "tok", nil, 1).data["headers"])
  end

  test "every push gives up a day after it is built, so endless retries end as a failure" do
    %w[ios android].each do |platform|
      app = platform == "ios" ? @apns_app : @fcm_app
      assert_in_delta 1.day.from_now, PushCampaigns::Payload.new(@campaign).build(platform, app, "tok", nil, 1).fail_after, 5
    end
  end

  test "unknown platform raises" do
    assert_raises(ArgumentError) { PushCampaigns::Payload.new(@campaign).build("web", @fcm_app, "tok") }
  end

  test "apns_bytesize measures the full APNs payload" do
    assert_operator PushCampaigns::Payload.new(@campaign).apns_bytesize, :>, 100
  end

  test "a campaign whose APNs payload would exceed 4096 bytes is invalid" do
    @campaign.body = "é" * 1000
    @campaign.image_url = "https://cdn/" + ("x" * 2000)
    assert_not @campaign.valid?
    assert_match(/4096/, @campaign.errors.full_messages.join)
  end
end
