require "test_helper"

class EventSerializerTest < ActiveSupport::TestCase
  fixtures :events, :projects, :devices, :instances

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION
  # ---------------------------------------------------------------------------

  test "serializes view_event with correct attribute values" do
    event = events(:view_event)
    result = EventSerializer.serialize(event)

    assert_equal event.id,                     result["id"]
    assert_equal "view",                       result["event"]
    assert_equal "/promo/spring",              result["path"]
    assert_equal "ios",                        result["platform"]
    assert_equal "192.168.1.100",              result["ip"]
    assert_equal "10.0.0.100",                 result["remote_ip"]
    assert_equal "1.5.0",                      result["app_version"]
    assert_equal "2026031901",                 result["build"]
    assert_equal '{"screen": "home"}',          result["data"]
    assert_equal 5000,                         result["engagement_time"]
    assert_equal "test-ios-vendor-001",        result["vendor_id"]
    assert_equal false,                        result["processed"]
  end

  test "serializes android_view_event with correct attribute values" do
    event = events(:android_view_event)
    result = EventSerializer.serialize(event)

    assert_equal event.id,                     result["id"]
    assert_equal "view",                       result["event"]
    assert_equal "/products",                  result["path"]
    assert_equal "android",                    result["platform"]
    assert_nil                                 result["ip"]
    assert_nil                                 result["remote_ip"]
    assert_equal "2.1.0",                      result["app_version"]
    assert_equal "2026031902",                 result["build"]
    assert_equal '{"screen": "catalog"}',       result["data"]
    assert_equal 2000,                         result["engagement_time"]
    assert_equal "test-android-vendor-001",    result["vendor_id"]
    assert_equal false,                        result["processed"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION — internal fields must NOT appear
  # ---------------------------------------------------------------------------

  test "excludes project_id link_id and device_id" do
    result = EventSerializer.serialize(events(:view_event))

    %w[project_id link_id device_id].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil EventSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING — verify size AND distinct values
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and distinct platforms" do
    result = EventSerializer.serialize([events(:view_event), events(:android_view_event)])

    assert_equal 2, result.size
    assert_equal "ios",     result[0]["platform"]
    assert_equal "android", result[1]["platform"]
    assert_equal 5000,      result[0]["engagement_time"]
    assert_equal 2000,      result[1]["engagement_time"]
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES
  # ---------------------------------------------------------------------------

  test "serializes empty collection as empty array" do
    result = EventSerializer.serialize([])
    assert_equal [], result
  end

  test "nil optional fields are present as keys with nil values" do
    result = EventSerializer.serialize(events(:web_app_open_event))

    %w[path ip remote_ip app_version build data vendor_id].each do |field|
      assert result.key?(field), "Expected key '#{field}' to be present in serialized output"
      assert_nil result[field]
    end
  end

  test "processed defaults to false" do
    result = EventSerializer.serialize(events(:view_event))
    assert_equal false, result["processed"]
  end
end
