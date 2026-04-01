require "test_helper"

class DeviceTest < ActiveSupport::TestCase
  fixtures :devices

  # === user_agent_platform ===

  test "user_agent_platform detects iOS from iPhone user agent" do
    device = devices(:ios_device)
    device.user_agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)"
    assert_equal Grovs::Platforms::IOS, device.user_agent_platform
  end

  test "user_agent_platform detects Android from Android user agent" do
    device = devices(:android_device)
    device.user_agent = "Mozilla/5.0 (Linux; Android 13; Pixel 7)"
    assert_equal Grovs::Platforms::ANDROID, device.user_agent_platform
  end

  test "user_agent_platform detects Windows from Windows user agent" do
    device = devices(:web_device)
    device.user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    assert_equal Grovs::Platforms::WINDOWS, device.user_agent_platform
  end

  test "user_agent_platform detects Mac from macOS user agent" do
    device = devices(:web_device)
    device.user_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
    assert_equal Grovs::Platforms::MAC, device.user_agent_platform
  end

  test "user_agent_platform falls back to WEB for unknown user agent" do
    device = devices(:web_device)
    device.user_agent = "Mozilla/5.0 (X11; Linux x86_64)"
    assert_equal Grovs::Platforms::WEB, device.user_agent_platform
  end

  # === platform_for_metrics ===

  test "platform_for_metrics preserves ios and android" do
    device = devices(:ios_device)
    device.platform = Grovs::Platforms::IOS
    assert_equal Grovs::Platforms::IOS, device.platform_for_metrics

    device.platform = Grovs::Platforms::ANDROID
    assert_equal Grovs::Platforms::ANDROID, device.platform_for_metrics
  end

  test "platform_for_metrics buckets all non-mobile platforms to web" do
    device = devices(:web_device)

    [Grovs::Platforms::DESKTOP, Grovs::Platforms::WINDOWS, Grovs::Platforms::MAC, Grovs::Platforms::WEB, nil, "unknown"].each do |plat|
      device.platform = plat
      assert_equal Grovs::Platforms::WEB, device.platform_for_metrics, "Expected Grovs::Platforms::WEB for platform=#{plat.inspect}"
    end
  end

  # === bot? ===

  test "bot? detects Facebook crawler" do
    device = devices(:web_device)
    device.user_agent = "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"
    assert device.bot?
  end

  test "bot? detects Twitter crawler" do
    device = devices(:web_device)
    device.user_agent = "Twitterbot/1.0"
    assert device.bot?
  end

  test "bot? detects Slack link expander" do
    device = devices(:web_device)
    device.user_agent = "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)"
    assert device.bot?
  end

  test "bot? detects WhatsApp preview" do
    device = devices(:web_device)
    device.user_agent = "WhatsApp/2.23.4.79 A"
    assert device.bot?
  end

  test "bot? returns false for real mobile browser" do
    device = devices(:ios_device)
    device.user_agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    assert_not device.bot?
  end

  test "bot? returns false for blank user agent" do
    device = devices(:web_device)
    device.user_agent = ""
    assert_not device.bot?
  end

  test "bot? returns false for nil user agent" do
    device = devices(:web_device)
    device.user_agent = nil
    assert_not device.bot?
  end

  # === fetch_by_hash_id ===

  test "fetch_by_hash_id round-trips through hashid encoding" do
    device = Device.create!(user_agent: "Test/1.0", ip: "1.2.3.4", remote_ip: "5.6.7.8")
    fetched = Device.fetch_by_hash_id(device.hashid)
    assert_equal device.id, fetched.id
  end

  test "fetch_by_hash_id returns nil for invalid hashid" do
    assert_nil Device.fetch_by_hash_id("totally-bogus-id")
  end

  # === cache_keys_to_clear ===

  test "cache_keys_to_clear includes vendor lookup key" do
    device = devices(:ios_device)
    device.vendor = "abc-123"
    keys = device.cache_keys_to_clear
    expected = "#{Device.cache_prefix}:find_by:vendor:abc-123:no_includes"
    assert_includes keys, expected
  end

  test "cache_keys_to_clear omits vendor key when vendor is blank" do
    device = devices(:ios_device)
    device.vendor = nil
    keys = device.cache_keys_to_clear
    assert_not keys.any? { |k| k.include?("vendor:") }
  end

  test "cache_keys_to_clear invalidates both old and new vendor on change" do
    device = Device.create!(user_agent: "Test/1.0", ip: "1.2.3.4", remote_ip: "5.6.7.8", vendor: "old-vendor")
    device.update!(vendor: "new-vendor")

    keys = device.cache_keys_to_clear
    prefix = Device.cache_prefix
    assert_includes keys, "#{prefix}:find_by:vendor:old-vendor:no_includes"
    assert_includes keys, "#{prefix}:find_by:vendor:new-vendor:no_includes"
  end

  # === visitor_for_project_id ===

  test "visitor_for_project_id delegates to Visitor with correct conditions and includes" do
    device = devices(:ios_device)
    captured = nil

    stub = lambda { |conditions, **opts|
      captured = { conditions: conditions, opts: opts }
      :sentinel
    }
    Visitor.stub(:redis_find_by_multiple_conditions, stub) do
      result = device.visitor_for_project_id(42)
      assert_equal :sentinel, result
    end

    assert_equal({ project_id: 42, device_id: device.id }, captured[:conditions])
    assert_equal [:device], captured[:opts][:includes]
  end
end
