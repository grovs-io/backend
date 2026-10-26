require "test_helper"

class EventStream::EnvelopeBuilderTest < ActiveSupport::TestCase
  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs, :links, :campaigns, :devices, :visitors

  setup do
    @project = projects(:one)
    @link = links(:basic_link)
    @device = devices(:ios_device)
    @visitor = visitors(:ios_visitor)
  end

  def row(over = {})
    {
      "event_id" => "abc123", "project_id" => @project.id, "event_type" => "install", "event_name" => "", "screen_name" => "Home",
      "device_id" => @device.id, "visitor_id" => @visitor.id, "link_id" => @link.id, "inviter_id" => 0, "campaign_id" => campaigns(:one).id,
      "platform" => "ios", "app_version" => "1.5.0", "build" => "12", "vendor_id" => "v", "device_model" => "iPhone15,2",
      "os" => "iOS", "os_version" => "18.6", "timezone" => "America/New_York", "language" => "en",
      "country" => "US", "city" => "Austin", "tracking_source" => "email", "tracking_medium" => "newsletter",
      "tracking_campaign" => "spring2026", "ads_platform" => "", "link_tags" => %w[promo],
      "sdk_identifier" => "user_ios_abc123", "sdk_attributes" => { "plan" => "gold" }, "session_id" => "s1",
      "engagement_time" => 0, "properties" => { "k" => 1 }, "tags" => [], "sdk_generated" => 0, "link_visitor_id" => @visitor.id,
      "ip" => "203.0.113.9", "remote_ip" => "203.0.113.9", "path" => "test-path",
      "created_at" => "2026-09-15 10:03:11.412", "ingested_at" => "2026-09-15 10:03:20.000"
    }.merge(over)
  end

  test "builds envelope v1 with hashids for project/device/visitor and integers for link/campaign" do
    env = EventStream::EnvelopeBuilder.new(project: @project, include_ip: false).build_events([row]).first
    assert_equal 1, env[:schema_version]
    assert_equal "abc123", env[:id]
    assert_equal "install", env[:type]
    assert_nil env[:name]
    assert_equal "2026-09-15T10:03:11.412Z", env[:occurred_at]
    assert_equal({ id: @project.hashid, test: false }, env[:project])
    assert_equal @link.id, env[:link][:id]
    assert_equal "test-path", env[:link][:path]
    assert_equal campaigns(:one).id, env[:link][:campaign_id]
    assert_equal "email", env[:link][:source]
    assert_equal @device.hashid, env[:device][:id]
    assert_equal "ios", env[:device][:platform]
    assert_equal({ id: "user_ios_abc123", attributes: { "plan" => "gold" } }, env[:user])
    assert_equal({ country: "US" }, env[:geo])
    assert_equal @visitor.hashid, env[:attribution][:link_visitor_id]
    assert_nil env[:attribution][:inviter_id]
    assert_equal false, env[:attribution][:sdk_generated]
    assert_equal({ "k" => 1 }, env[:properties])
    assert_nil env[:purchase]
    assert_nil env[:caused_by]
  end

  test "custom events carry name; user_referred carries caused_by; include_ip adds ip and city" do
    b = EventStream::EnvelopeBuilder.new(project: @project, include_ip: true)
    custom = b.build_events([row("event_type" => "custom", "event_name" => "checkout")]).first
    assert_equal "custom", custom[:type]
    assert_equal "checkout", custom[:name]
    assert_equal({ country: "US", city: "Austin", ip: "203.0.113.9" }, custom[:geo])

    referred = b.build_events([row("event_type" => "user_referred", "properties" => { "install_event_id" => "inst1" })]).first
    assert_equal "inst1", referred[:caused_by]
  end

  test "a link or visitor from another project never reaches the envelope" do
    env = EventStream::EnvelopeBuilder.new(project: @project, include_ip: false)
                                      .build_events([row("link_id" => links(:second_link).id)]).first
    assert_equal links(:second_link).id, env[:link][:id]
    assert_nil env[:link][:path]
  end

  test "missing link and zero ids become nil groups" do
    env = EventStream::EnvelopeBuilder.new(project: @project, include_ip: false)
                                      .build_events([row("link_id" => 0, "link_visitor_id" => 0, "visitor_id" => 0)]).first
    assert_nil env[:link]
    assert_nil env[:attribution][:link_visitor_id]
  end

  test "purchase envelope id changes with version and carries purchase group" do
    prow = { "project_id" => @project.id, "event_type" => "buy", "purchase_type" => "subscription", "product_id" => "pro.monthly",
             "usd_price_cents" => 499, "currency" => "USD", "quantity" => 1, "transaction_id" => "t1", "original_transaction_id" => "t0",
             "store_source" => "apple", "device_id" => @device.id, "link_id" => @link.id, "visitor_id" => @visitor.id,
             "purchase_date" => "2026-09-15 10:00:00.000", "created_at" => "2026-09-15 10:03:20.000", "session_id" => "s1",
             "recorded_at" => "1970-01-01 00:00:00.000", "platform" => "ios" }
    b = EventStream::EnvelopeBuilder.new(project: @project, include_ip: false)
    e1 = b.build_purchases([prow]).first
    e2 = b.build_purchases([prow.merge("created_at" => "2026-09-15 11:00:00.000")]).first
    assert_equal "purchase", e1[:type]
    assert_equal "buy", e1[:name]
    assert_not_equal e1[:id], e2[:id]
    assert_equal "t1", e1[:purchase][:transaction_id]
    assert_equal 499, e1[:purchase][:usd_price_cents]
    assert_equal "2026-09-15T10:03:20.000Z", e1[:purchase][:version]
    assert_equal "user_ios_abc123", e1[:user][:id]
  end
end
