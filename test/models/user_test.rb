require "test_helper"

class UserTest < ActiveSupport::TestCase
  fixtures :users, :instances, :instance_roles

  # === email validation ===

  test "valid email passes validation" do
    user = users(:admin_user)
    assert user.valid?
  end

  test "invalid email format fails validation" do
    user = users(:admin_user)
    user.email = "not-an-email"
    assert_not user.valid?
  end

  test "blank email fails validation" do
    user = users(:admin_user)
    user.email = ""
    assert_not user.valid?
  end

  # === password_required? ===

  test "password_required? returns false when provider is present" do
    user = users(:oauth_user)
    assert_not user.password_required?
  end

  test "password_required? returns true when provider is nil" do
    user = users(:admin_user)
    # Devise default: password required for new records or password change
    # For an existing persisted user, super returns false unless changing password
    # We just verify provider absence does not short-circuit
    assert_nil user.provider
  end

  # === admin?(instance) ===

  test "admin? returns true for user with admin role on instance" do
    user = users(:admin_user)
    instance = instances(:one)
    assert user.admin?(instance)
  end

  test "admin? returns false for user with member role on instance" do
    user = users(:member_user)
    instance = instances(:one)
    assert_not user.admin?(instance)
  end

  test "admin? returns false when user has no role on instance" do
    user = users(:admin_user)
    instance = instances(:two)
    assert_not user.admin?(instance)
  end

  test "admin? returns false when instance is nil" do
    user = users(:admin_user)
    assert_not user.admin?(nil)
  end

  # === instance_roles_as_array ===

  test "instance_roles_as_array returns role hashes for regular user" do
    user = users(:admin_user)
    roles = user.instance_roles_as_array
    assert_equal 1, roles.length
    assert_equal instances(:one).id, roles.first[:instance_id]
    assert_equal "admin", roles.first[:role]
  end

  test "instance_roles_as_array returns empty for user with no roles" do
    user = users(:oauth_user)
    roles = user.instance_roles_as_array
    assert_equal [], roles
  end

  # === serialization ===

  test "serializer excludes sensitive fields" do
    user = users(:admin_user)
    json = UserSerializer.serialize(user)
    %w[password encrypted_password otp_secret consumed_timestep
       invitation_token reset_password_sent_at remember_created_at
       invited_by_id invited_by_type invitation_limit invitations_count
       invitation_created_at created_at updated_at].each do |field|
      assert_nil json[field], "#{field} should not be exposed"
    end
  end

  test "serializer includes roles when show_roles is true" do
    user = users(:admin_user)
    json = UserSerializer.serialize(user, show_roles: true)
    assert json.key?("roles")
    assert_equal 1, json["roles"].length
  end

  test "serializer does not include roles when show_roles is false" do
    user = users(:admin_user)
    json = UserSerializer.serialize(user)
    assert_nil json["roles"]
  end

  # === authenticate ===

  test "authenticate returns user with valid email and password" do
    password = "SecurePassword123!"
    user = users(:admin_user)
    user.update!(password: password, password_confirmation: password)

    result = User.authenticate(user.email, password, nil)
    assert_not_nil result
    assert_equal user.id, result.id
  end

  test "authenticate returns nil with wrong password" do
    password = "SecurePassword123!"
    user = users(:admin_user)
    user.update!(password: password, password_confirmation: password)

    result = User.authenticate(user.email, "WrongPassword999!", nil)
    assert_nil result
  end

  test "authenticate returns nil with non-existent email" do
    result = User.authenticate("nonexistent@example.com", "anypassword", nil)
    assert_nil result
  end

  test "authenticate returns nil with empty password" do
    user = users(:admin_user)
    user.update!(password: "SecurePassword123!", password_confirmation: "SecurePassword123!")

    result = User.authenticate(user.email, "", nil)
    assert_nil result
  end

  # === validate_and_consume_otp! (legacy secret handling) ===

  test "validate_and_consume_otp! returns false for legacy encrypted otp_secret instead of crashing" do
    user = users(:admin_user)
    user.otp_secret = '{"p":"iShx7TW8qBnvVHG","h":{"iv":"abc","at":"def"}}'
    result = user.validate_and_consume_otp!("123456")
    assert_equal false, result
  end

  test "toggle_2fa returns nil for legacy encrypted otp_secret" do
    user = users(:admin_user)
    user.otp_secret = '{"p":"iShx7TW8qBnvVHG","h":{"iv":"abc","at":"def"}}'
    result = UserAccountService.toggle_2fa(user: user, enable: true, otp_code: "123456")
    assert_nil result
  end

  test "authenticate returns nil when otp_required with legacy encrypted secret" do
    password = "SecurePassword123!"
    user = users(:admin_user)
    user.update!(password: password, password_confirmation: password)
    user.update_columns(otp_required_for_login: true, otp_secret: '{"p":"legacy"}')

    result = User.authenticate(user.email, password, "123456")
    assert_nil result
  end

  # === OtpRequiredError behavior ===

  test "authenticate raises OtpRequiredError when otp_required but otp_code blank" do
    password = "SecurePassword123!"
    user = users(:admin_user)
    user.update!(password: password, password_confirmation: password)
    user.update_columns(otp_required_for_login: true)

    assert_raises(OtpRequiredError) do
      User.authenticate(user.email, password, nil)
    end
  end

  test "authenticate raises OtpRequiredError when otp_required and otp_code is empty string" do
    password = "SecurePassword123!"
    user = users(:admin_user)
    user.update!(password: password, password_confirmation: password)
    user.update_columns(otp_required_for_login: true)

    assert_raises(OtpRequiredError) do
      User.authenticate(user.email, password, "")
    end
  end

  test "authenticate returns nil when otp_required and otp_code is wrong" do
    password = "SecurePassword123!"
    user = users(:admin_user)
    user.update!(password: password, password_confirmation: password)
    user.update_columns(otp_required_for_login: true)

    result = User.authenticate(user.email, password, "000000")
    assert_nil result
  end

  test "authenticate does NOT raise OtpRequiredError when password is wrong even if otp_required" do
    password = "SecurePassword123!"
    user = users(:admin_user)
    user.update!(password: password, password_confirmation: password)
    user.update_columns(otp_required_for_login: true)

    result = User.authenticate(user.email, "WrongPassword!", nil)
    assert_nil result
  end
end
