require "test_helper"

class InstanceRoleSerializerTest < ActiveSupport::TestCase
  fixtures :instance_roles, :instances, :users

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION — assert_equal for every attribute
  # ---------------------------------------------------------------------------

  test "serializes admin_role with correct attribute values" do
    role = instance_roles(:admin_role)
    result = InstanceRoleSerializer.serialize(role)

    assert_equal instances(:one).id, result["instance_id"]
    assert_equal "admin",          result["role"]
  end

  test "serializes member_role with correct attribute values" do
    role = instance_roles(:member_role)
    result = InstanceRoleSerializer.serialize(role)

    assert_equal instances(:one).id, result["instance_id"]
    assert_equal "member",         result["role"]
  end

  # ---------------------------------------------------------------------------
  # 2. NESTED USER — verify actual values, not just key presence
  # ---------------------------------------------------------------------------

  test "nested user hash contains correct values for admin_user" do
    role = instance_roles(:admin_role)
    result = InstanceRoleSerializer.serialize(role)
    user = role.user

    assert_instance_of Hash, result["user"]
    assert_equal user.id,                  result["user"]["id"]
    assert_equal "admin@example.com",      result["user"]["email"]
    assert_equal "Admin User",             result["user"]["name"]
    assert_nil result["user"]["otp_required_for_login"]
    assert_nil result["user"]["provider"]
    assert_nil result["user"]["uid"]
    assert_nil result["user"]["invitation_accepted_at"]
    assert_nil result["user"]["invitation_sent_at"]
    # Sensitive fields must not be exposed
    %w[invitation_token invited_by_id invited_by_type invitation_limit
       invitations_count invitation_created_at remember_created_at
       reset_password_sent_at otp_secret consumed_timestep].each do |field|
      assert_not_includes result["user"].keys, field, "#{field} should not be exposed"
    end
  end

  test "nested user hash contains correct values for member_user" do
    role = instance_roles(:member_role)
    result = InstanceRoleSerializer.serialize(role)

    assert_instance_of Hash, result["user"]
    assert_equal "member@example.com", result["user"]["email"]
    assert_equal "Member User",        result["user"]["name"]
  end

  test "nested user excludes encrypted_password" do
    result = InstanceRoleSerializer.serialize(instance_roles(:admin_role))

    assert_not_includes result["user"].keys, "encrypted_password"
  end

  test "nested user does not include roles by default" do
    result = InstanceRoleSerializer.serialize(instance_roles(:admin_role))

    assert_not_includes result["user"].keys, "roles"
  end

  # ---------------------------------------------------------------------------
  # 3. EXCLUSION — internal fields must NOT appear
  # ---------------------------------------------------------------------------

  test "excludes updated_at created_at user_id and id" do
    result = InstanceRoleSerializer.serialize(instance_roles(:admin_role))

    %w[updated_at created_at user_id id].each do |field|
      assert_not_includes result.keys, field,
        "Expected serialized output to exclude '#{field}'"
    end
  end

  test "top-level keys are exactly instance_id role user" do
    result = InstanceRoleSerializer.serialize(instance_roles(:admin_role))

    expected_keys = %w[instance_id role user]
    assert_equal expected_keys, result.keys.sort
  end

  # ---------------------------------------------------------------------------
  # 4. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil InstanceRoleSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 5. COLLECTION HANDLING
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and distinct roles" do
    roles = [instance_roles(:admin_role), instance_roles(:member_role)]
    result = InstanceRoleSerializer.serialize(roles)

    assert_equal 2, result.size
    assert_equal "admin",  result[0]["role"]
    assert_equal "member", result[1]["role"]
  end

  test "collection items have distinct user emails" do
    roles = [instance_roles(:admin_role), instance_roles(:member_role)]
    result = InstanceRoleSerializer.serialize(roles)

    assert_equal "admin@example.com",  result[0]["user"]["email"]
    assert_equal "member@example.com", result[1]["user"]["email"]
  end

  test "both roles reference the same instance" do
    roles = [instance_roles(:admin_role), instance_roles(:member_role)]
    result = InstanceRoleSerializer.serialize(roles)

    assert_equal instances(:one).id, result[0]["instance_id"]
    assert_equal instances(:one).id, result[1]["instance_id"]
  end

  test "serializes empty collection as empty array" do
    result = InstanceRoleSerializer.serialize([])
    assert_equal [], result
  end
end
