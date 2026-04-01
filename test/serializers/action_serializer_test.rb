require "test_helper"

class ActionSerializerTest < ActiveSupport::TestCase
  fixtures :actions, :devices, :links, :domains, :projects, :instances,
           :redirect_configs, :custom_redirects

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION — assert_equal for every attribute
  # ---------------------------------------------------------------------------

  test "serializes recent_action with correct attribute values" do
    action = actions(:recent_action)
    result = ActionSerializer.serialize(action)

    assert_equal action.id,                      result["id"]
    assert_equal false,                          result["handled"]
  end

  test "serializes action_for_second_link with correct attribute values" do
    action = actions(:action_for_second_link)
    result = ActionSerializer.serialize(action)

    assert_equal action.id,                      result["id"]
    assert_equal false,                          result["handled"]
  end

  # ---------------------------------------------------------------------------
  # 2. NESTED DEVICE — verify actual values, not just key presence
  # ---------------------------------------------------------------------------

  test "nested device hash contains correct values for ios_device" do
    action = actions(:recent_action)
    result = ActionSerializer.serialize(action)
    device = action.device

    assert_instance_of Hash, result["device"]
    assert_equal device.id,                        result["device"]["id"]
    assert_equal "ios",                            result["device"]["platform"]
    assert_equal "iPhone 15 Pro",                  result["device"]["model"]
    assert_equal "1.5.0",                          result["device"]["app_version"]
    assert_equal "2026031901",                     result["device"]["build"]
    assert_equal "en",                             result["device"]["language"]
    assert_equal "America/New_York",               result["device"]["timezone"]
    assert_equal 1179,                             result["device"]["screen_width"]
    assert_equal 2556,                             result["device"]["screen_height"]
  end

  test "nested device for action_for_second_link is android" do
    action = actions(:action_for_second_link)
    result = ActionSerializer.serialize(action)
    device = action.device

    assert_instance_of Hash, result["device"]
    assert_equal device.id,     result["device"]["id"]
    assert_equal "android",     result["device"]["platform"]
  end

  test "nested device excludes user_agent vendor ip remote_ip and push_token" do
    result = ActionSerializer.serialize(actions(:recent_action))

    %w[user_agent vendor ip remote_ip push_token].each do |field|
      assert_not_includes result["device"].keys, field,
        "Expected device hash to exclude '#{field}'"
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NESTED LINK — verify actual values, not just key presence
  # ---------------------------------------------------------------------------

  test "nested link hash contains correct values for basic_link" do
    action = actions(:recent_action)
    result = ActionSerializer.serialize(action)
    link = action.link

    assert_instance_of Hash, result["link"]
    assert_equal link.id,                          result["link"]["id"]
    assert_equal "Spring Campaign Link",           result["link"]["name"]
    assert_equal "test-path",                      result["link"]["path"]
    assert_equal "Test Link",                      result["link"]["title"]
    assert_equal "A test link",                    result["link"]["subtitle"]
    assert_equal true,                             result["link"]["active"]
    assert_equal false,                            result["link"]["sdk_generated"]
    assert_equal '[{"key": "value"}]',              result["link"]["data"]
    assert_equal ["promo", "social"],              result["link"]["tags"]
    assert_nil result["link"]["show_preview_ios"]
    assert_nil result["link"]["show_preview_android"]
    assert_nil result["link"]["ads_platform"]
    assert_equal "ios",                            result["link"]["generated_from_platform"]
    assert_equal "email",                          result["link"]["tracking_source"]
    assert_equal "newsletter",                     result["link"]["tracking_medium"]
    assert_equal "spring2026",                     result["link"]["tracking_campaign"]
    assert_nil result["link"]["visitor_id"]
    assert_nil result["link"]["campaign_id"]
    assert_nil result["link"]["image"]
    assert_equal link.access_path,                 result["link"]["access_path"]
  end

  test "nested link has custom redirect hashes with correct values" do
    result = ActionSerializer.serialize(actions(:recent_action))
    link_hash = result["link"]

    assert_instance_of Hash, link_hash["ios_custom_redirect"]
    assert_equal "https://example.com/ios-custom",     link_hash["ios_custom_redirect"]["url"]
    assert_equal true,                                 link_hash["ios_custom_redirect"]["open_app_if_installed"]

    assert_instance_of Hash, link_hash["android_custom_redirect"]
    assert_equal "https://example.com/android-custom", link_hash["android_custom_redirect"]["url"]
    assert_equal false,                                link_hash["android_custom_redirect"]["open_app_if_installed"]

    assert_instance_of Hash, link_hash["desktop_custom_redirect"]
    assert_equal "https://example.com/desktop-custom", link_hash["desktop_custom_redirect"]["url"]
    assert_equal false,                                link_hash["desktop_custom_redirect"]["open_app_if_installed"]
  end

  test "nested link for action_for_second_link has second_link values" do
    action = actions(:action_for_second_link)
    result = ActionSerializer.serialize(action)

    assert_equal "second-path",       result["link"]["path"]
    assert_equal "Second Link",       result["link"]["title"]
    assert_equal "Another test link", result["link"]["subtitle"]
    assert_equal "android",           result["link"]["generated_from_platform"]
  end

  # ---------------------------------------------------------------------------
  # 4. EXCLUSION — internal fields must NOT appear
  # ---------------------------------------------------------------------------

  test "excludes device_id and link_id" do
    result = ActionSerializer.serialize(actions(:recent_action))

    assert_not_includes result.keys, "device_id"
    assert_not_includes result.keys, "link_id"
  end

  test "top-level keys are exactly id handled created_at updated_at device link" do
    result = ActionSerializer.serialize(actions(:recent_action))

    expected_keys = %w[created_at device handled id link updated_at]
    assert_equal expected_keys, result.keys.sort
  end

  # ---------------------------------------------------------------------------
  # 5. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil ActionSerializer.serialize(nil)
  end

  test "device and link are nil when associations are missing" do
    action = actions(:recent_action)
    action.stub(:device, nil) do
      action.stub(:link, nil) do
        result = ActionSerializer.serialize(action)
        assert_nil result["device"]
        assert_nil result["link"]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 6. COLLECTION HANDLING
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and distinct ids" do
    action_list = [actions(:recent_action), actions(:action_for_second_link)]
    result = ActionSerializer.serialize(action_list)

    assert_equal 2, result.size
    assert_equal actions(:recent_action).id,          result[0]["id"]
    assert_equal actions(:action_for_second_link).id, result[1]["id"]
  end

  test "collection items have distinct device platforms" do
    action_list = [actions(:recent_action), actions(:action_for_second_link)]
    result = ActionSerializer.serialize(action_list)

    assert_equal "ios",     result[0]["device"]["platform"]
    assert_equal "android", result[1]["device"]["platform"]
  end

  test "serializes empty collection as empty array" do
    result = ActionSerializer.serialize([])
    assert_equal [], result
  end
end
