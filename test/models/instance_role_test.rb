require "test_helper"

class InstanceRoleTest < ActiveSupport::TestCase
  fixtures :instance_roles, :instances, :users

  # === validations ===

  test "valid with admin role" do
    role = InstanceRole.new(
      instance: instances(:one),
      user: users(:super_admin_user),
      role: Grovs::Roles::ADMIN
    )
    assert role.valid?
  end

  test "valid with member role" do
    role = InstanceRole.new(
      instance: instances(:one),
      user: users(:super_admin_user),
      role: Grovs::Roles::MEMBER
    )
    assert role.valid?
  end

  test "invalid with unknown role" do
    role = InstanceRole.new(
      instance: instances(:one),
      user: users(:super_admin_user),
      role: "superuser"
    )
    assert_not role.valid?
    assert_includes role.errors[:role], "is not included in the list"
  end

  test "invalid with blank role" do
    role = InstanceRole.new(
      instance: instances(:one),
      user: users(:super_admin_user),
      role: ""
    )
    assert_not role.valid?
  end

  # === is_user_admin ===

  test "is_user_admin returns true for admin user" do
    result = InstanceRole.is_user_admin(users(:admin_user), instances(:one))
    assert_equal true, result
  end

  test "is_user_admin returns false for member user" do
    result = InstanceRole.is_user_admin(users(:member_user), instances(:one))
    assert_equal false, result
  end

  test "is_user_admin returns false for user with no role in instance" do
    result = InstanceRole.is_user_admin(users(:super_admin_user), instances(:one))
    assert_equal false, result
  end

  test "is_user_admin returns false when user is nil" do
    result = InstanceRole.is_user_admin(nil, instances(:one))
    assert_equal false, result
  end

  test "is_user_admin returns false when instance is nil" do
    result = InstanceRole.is_user_admin(users(:admin_user), nil)
    assert_equal false, result
  end

  # === role_for_user_and_instance ===

  test "role_for_user_and_instance returns the role for an admin" do
    role = InstanceRole.role_for_user_and_instance(users(:admin_user), instances(:one))
    assert_equal Grovs::Roles::ADMIN, role.role
  end

  test "role_for_user_and_instance returns the role for a member" do
    role = InstanceRole.role_for_user_and_instance(users(:member_user), instances(:one))
    assert_equal Grovs::Roles::MEMBER, role.role
  end

  test "role_for_user_and_instance returns nil for user with no role" do
    result = InstanceRole.role_for_user_and_instance(users(:super_admin_user), instances(:one))
    assert_nil result
  end

  test "role_for_user_and_instance returns nil when user is nil" do
    result = InstanceRole.role_for_user_and_instance(nil, instances(:one))
    assert_nil result
  end

  test "role_for_user_and_instance returns nil when instance is nil" do
    result = InstanceRole.role_for_user_and_instance(users(:admin_user), nil)
    assert_nil result
  end

  # === serialization ===

  test "serializer excludes updated_at, created_at, project_id, user_id, and id" do
    role = instance_roles(:admin_role)
    json = InstanceRoleSerializer.serialize(role)

    assert_not json.key?("updated_at")
    assert_not json.key?("created_at")
    assert_not json.key?("project_id")
    assert_not json.key?("user_id")
    assert_not json.key?("id")
  end

  test "serializer includes user key" do
    role = instance_roles(:admin_role)
    json = InstanceRoleSerializer.serialize(role)

    assert json.key?("user")
  end
end
