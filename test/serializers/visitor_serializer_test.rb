require "test_helper"

class VisitorSerializerTest < ActiveSupport::TestCase
  fixtures :visitors, :devices, :projects, :instances

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION -- assert_equal for every declared attribute
  # ---------------------------------------------------------------------------
  test "serializes every declared attribute with correct values" do
    visitor = visitors(:ios_visitor)
    result = VisitorSerializer.serialize(visitor)

    assert_equal visitor.id,                                     result["id"]
    assert_equal "550e8400-e29b-41d4-a716-446655440001",         result["uuid"]
    assert_equal "user_ios_abc123",                              result["sdk_identifier"]
    attrs = result["sdk_attributes"]
    attrs = JSON.parse(attrs) if attrs.is_a?(String)
    assert_equal({"plan" => "premium", "age_group" => "25-34"}, attrs)
    assert_nil result["inviter_id"]
    assert_equal false,                                          result["web_visitor"]
  end

  test "default mode includes inviter and invited with correct values" do
    visitor = visitors(:ios_visitor)
    result = VisitorSerializer.serialize(visitor)

    # inviter is nil when no inviter is set
    assert_nil result["inviter"]
    # invited is an array (may be empty)
    assert_kind_of Array, result["invited"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION -- internal fields must NOT appear
  # ---------------------------------------------------------------------------
  test "excludes device_id and project_id" do
    visitor = visitors(:ios_visitor)
    result = VisitorSerializer.serialize(visitor)

    %w[device_id project_id].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING -- returns nil for nil input
  # ---------------------------------------------------------------------------
  test "returns nil for nil input" do
    assert_nil VisitorSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING -- verify size AND distinct values
  # ---------------------------------------------------------------------------
  test "serializes a collection with correct size and distinct ids" do
    visitor_a = visitors(:ios_visitor)
    visitor_b = visitors(:android_visitor)
    results = VisitorSerializer.serialize([visitor_a, visitor_b])

    assert_equal 2, results.size

    ids = results.map { |r| r["id"] }
    assert_equal ids.uniq.size, ids.size
    assert_includes ids, visitor_a.id
    assert_includes ids, visitor_b.id
  end

  test "empty collection returns empty array" do
    assert_equal [], VisitorSerializer.serialize([])
  end

  # ---------------------------------------------------------------------------
  # 5. SLIM MODE -- excludes inviter and invited, keeps declared attributes
  # ---------------------------------------------------------------------------
  test "slim mode excludes inviter and invited" do
    visitor = visitors(:ios_visitor)
    result = VisitorSerializer.serialize(visitor, slim: true)

    assert_not_includes result.keys, "inviter"
    assert_not_includes result.keys, "invited"

    # Declared attributes still present
    assert_equal visitor.id,                              result["id"]
    assert_equal "550e8400-e29b-41d4-a716-446655440001",  result["uuid"]
    assert_equal false,                                   result["web_visitor"]
  end

  test "slim mode still excludes internal fields" do
    visitor = visitors(:ios_visitor)
    result = VisitorSerializer.serialize(visitor, slim: true)

    %w[device_id project_id].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 6. SKIP_INVITES -- keeps inviter, excludes invited
  # ---------------------------------------------------------------------------
  test "skip_invites keeps inviter but excludes invited" do
    visitor = visitors(:ios_visitor)
    result = VisitorSerializer.serialize(visitor, skip_invites: true)

    assert_includes result.keys, "inviter"
    assert_not_includes result.keys, "invited"
  end

  # ---------------------------------------------------------------------------
  # 7. SIMPLE -- includes uuid, excludes inviter_id
  # ---------------------------------------------------------------------------
  test "simple includes uuid and excludes inviter_id and internal fields" do
    visitor = visitors(:ios_visitor)
    result = VisitorSerializer.simple(visitor)

    assert_equal "550e8400-e29b-41d4-a716-446655440001",  result["uuid"]
    assert_equal visitor.id,                              result["id"]
    assert_equal "user_ios_abc123",                       result["sdk_identifier"]
    assert_equal false,                                   result["web_visitor"]

    assert_not_includes result.keys, "inviter_id"
    assert_not_includes result.keys, "device_id"
    assert_not_includes result.keys, "project_id"
  end

  test "simple returns nil for nil input" do
    assert_nil VisitorSerializer.simple(nil)
  end

  # ---------------------------------------------------------------------------
  # 8. RELATIONSHIP TESTS -- inviter and invited with real data
  # ---------------------------------------------------------------------------
  test "inviter returns sdk_identifier of the inviting visitor" do
    inviter = visitors(:ios_visitor)
    inviter.update!(sdk_identifier: "inviter-sdk-id")
    invited = visitors(:android_visitor)
    invited.update!(inviter: inviter)

    result = VisitorSerializer.serialize(invited)

    assert_equal "inviter-sdk-id", result["inviter"]
  end

  test "invited list contains simple-serialized visitors with correct values" do
    inviter = visitors(:ios_visitor)
    invited = visitors(:android_visitor)
    invited.update!(inviter: inviter)

    result = VisitorSerializer.serialize(inviter)

    assert_kind_of Array, result["invited"]
    assert_equal 1, result["invited"].size

    invited_entry = result["invited"].first
    assert_equal "550e8400-e29b-41d4-a716-446655440002", invited_entry["uuid"]
    assert_equal invited.id,                            invited_entry["id"]
    assert_not_includes invited_entry.keys, "inviter_id"
  end
end
