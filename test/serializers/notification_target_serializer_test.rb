require "test_helper"

class NotificationTargetSerializerTest < ActiveSupport::TestCase
  fixtures :notification_targets, :notifications, :projects, :instances, :domains

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION
  # ---------------------------------------------------------------------------

  test "serializes target one with correct attribute values" do
    target = notification_targets(:one)
    result = NotificationTargetSerializer.serialize(target)

    assert_equal target.id,                result["id"]
    assert_equal true,                     result["existing_users"]
    assert_equal false,                    result["new_users"]
    assert_equal ["ios", "android"],       result["platforms"]
  end

  test "serializes target two with correct attribute values" do
    target = notification_targets(:two)
    result = NotificationTargetSerializer.serialize(target)

    assert_equal target.id,                result["id"]
    assert_equal false,                    result["existing_users"]
    assert_equal true,                     result["new_users"]
    assert_equal ["web"],                  result["platforms"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION — internal fields must NOT appear
  # ---------------------------------------------------------------------------

  test "excludes created_at updated_at and notification_id" do
    result = NotificationTargetSerializer.serialize(notification_targets(:one))

    %w[created_at updated_at notification_id].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil NotificationTargetSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING — verify size AND distinct values
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and distinct ids" do
    targets = [notification_targets(:one), notification_targets(:two)]
    result = NotificationTargetSerializer.serialize(targets)

    assert_equal 2, result.size
    assert_equal notification_targets(:one).id, result[0]["id"]
    assert_equal notification_targets(:two).id, result[1]["id"]
    assert_not_equal result[0]["id"], result[1]["id"]
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES
  # ---------------------------------------------------------------------------

  test "serializes empty collection as empty array" do
    result = NotificationTargetSerializer.serialize([])
    assert_equal [], result
  end

  test "only exposes exactly four keys" do
    result = NotificationTargetSerializer.serialize(notification_targets(:one))

    assert_equal %w[existing_users id new_users platforms], result.keys.sort
  end

  test "boolean fields are actual booleans not strings" do
    result = NotificationTargetSerializer.serialize(notification_targets(:one))

    assert_instance_of TrueClass,  result["existing_users"]
    assert_instance_of FalseClass, result["new_users"]
  end

  test "platforms is an array not a string" do
    result = NotificationTargetSerializer.serialize(notification_targets(:one))

    assert_instance_of Array, result["platforms"]
  end
end
