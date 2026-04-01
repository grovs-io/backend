require "test_helper"

class UserSerializerTest < ActiveSupport::TestCase
  fixtures :users, :instance_roles, :instances

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION -- assert_equal for every declared attribute
  # ---------------------------------------------------------------------------
  test "serializes every declared attribute with correct values for admin_user" do
    user = users(:admin_user)
    result = UserSerializer.serialize(user)

    assert_equal user.id,                              result["id"]
    assert_equal "admin@example.com",                  result["email"]
    assert_equal "Admin User",                         result["name"]
    assert_nil result["otp_required_for_login"]
    assert_nil result["provider"]
    assert_nil result["uid"]
    assert_nil result["invitation_accepted_at"]
    assert_nil result["invitation_sent_at"]
  end

  test "serializes oauth_user with provider and uid values" do
    user = users(:oauth_user)
    result = UserSerializer.serialize(user)

    assert_equal "google_oauth2", result["provider"]
    assert_equal "123456789",     result["uid"]
    assert_equal "OAuth User",    result["name"]
  end

  test "serializes member_user with correct email and name" do
    user = users(:member_user)
    result = UserSerializer.serialize(user)

    assert_equal "member@example.com", result["email"]
    assert_equal "Member User",        result["name"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION -- internal/sensitive fields must NOT appear
  # ---------------------------------------------------------------------------
  test "excludes sensitive and internal fields" do
    user = users(:admin_user)
    result = UserSerializer.serialize(user)

    %w[updated_at created_at password otp_secret consumed_timestep encrypted_password
       invitation_token invited_by_id invited_by_type invitation_limit
       invitations_count invitation_created_at remember_created_at
       reset_password_sent_at].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING -- returns nil for nil input
  # ---------------------------------------------------------------------------
  test "returns nil for nil input" do
    assert_nil UserSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING -- verify size AND distinct values
  # ---------------------------------------------------------------------------
  test "serializes a collection with correct size and distinct emails" do
    user_a = users(:admin_user)
    user_b = users(:member_user)
    results = UserSerializer.serialize([user_a, user_b])

    assert_equal 2, results.size

    emails = results.map { |r| r["email"] }
    assert_includes emails, "admin@example.com"
    assert_includes emails, "member@example.com"
    assert_equal emails.uniq.size, emails.size
  end

  test "empty collection returns empty array" do
    assert_equal [], UserSerializer.serialize([])
  end

  # ---------------------------------------------------------------------------
  # 5. SHOW_ROLES OPTION
  # ---------------------------------------------------------------------------
  test "default mode does not include roles key" do
    user = users(:admin_user)
    result = UserSerializer.serialize(user)

    assert_not_includes result.keys, "roles"
  end

  test "show_roles true includes roles array with correct structure" do
    user = users(:admin_user)
    result = UserSerializer.serialize(user, show_roles: true)

    assert_includes result.keys, "roles"
    assert_kind_of Array, result["roles"]
    assert_operator result["roles"].size, :>=, 1

    # The admin_user has an admin role on instance one
    role_entry = result["roles"].find { |r| r[:instance_id] == instances(:one).id }
    assert_not_nil role_entry
    assert_equal "admin", role_entry[:role]
  end

  test "show_roles for member_user returns member role" do
    user = users(:member_user)
    result = UserSerializer.serialize(user, show_roles: true)

    assert_kind_of Array, result["roles"]
    role_entry = result["roles"].find { |r| r[:instance_id] == instances(:one).id }
    assert_not_nil role_entry
    assert_equal "member", role_entry[:role]
  end

end
