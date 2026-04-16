require "test_helper"

class UserAccountServiceTest < ActiveSupport::TestCase
  fixtures :instances

  setup do
    @email = "newuser_#{SecureRandom.hex(4)}@test.com"
    @password = "password123"
    @name = "Test User"
  end

  # === register ===

  test "register creates a new user with correct attributes" do
    WelcomeMailer.stub(:welcome, OpenStruct.new(deliver_later: true)) do
      assert_difference "User.count", 1 do
        user = UserAccountService.register(email: @email, password: @password, name: @name)
        assert user.persisted?
        assert_equal @email, user.email
        assert_equal @name, user.name
        assert user.valid_password?(@password), "User should be able to authenticate with given password"
      end
    end
  end

  test "register accepts pending invitation and clears invitation state" do
    invited_user = User.invite!({ email: @email }, User.create!(email: "inviter@test.com", password: "password123"))
    assert invited_user.invitation_token.present?
    original_id = invited_user.id

    WelcomeMailer.stub(:welcome, OpenStruct.new(deliver_later: true)) do
      assert_no_difference "User.count" do
        user = UserAccountService.register(email: @email, password: @password, name: @name)
        assert_equal original_id, user.id
        assert_equal @name, user.name
        assert user.valid_password?(@password), "Invited user should authenticate with new password"

        user.reload
        assert_nil user.invitation_token, "Invitation token should be cleared"
        assert user.invitation_accepted_at.present?, "Invitation accepted timestamp should be set"
      end
    end
  end

  test "register raises for existing non-invited user" do
    User.create!(email: @email, password: @password, name: @name)

    error = assert_raises(ArgumentError) do
      UserAccountService.register(email: @email, password: @password, name: @name)
    end
    assert_match(/already exists/, error.message)
  end

  test "register does not accept already-accepted invitation" do
    inviter = User.create!(email: "inviter_nodup@test.com", password: "password123")
    invited = User.invite!({ email: @email }, inviter)
    User.accept_invitation!(invitation_token: invited.raw_invitation_token, password: "accepted123")

    assert_raises(ArgumentError) do
      UserAccountService.register(email: @email, password: @password, name: @name)
    end
  end

  # === request_password_reset ===

  test "request_password_reset returns user and sets reset token" do
    user = User.create!(email: @email, password: @password)
    assert_nil user.reset_password_token

    result = UserAccountService.request_password_reset(email: @email)
    assert_equal user.id, result.id

    user.reload
    assert user.reset_password_token.present?, "Reset password token should be set after requesting reset"
  end

  test "request_password_reset returns nil for unknown email" do
    result = UserAccountService.request_password_reset(email: "nonexistent@test.com")
    assert_nil result
  end

  # === reset_password ===

  test "reset_password changes password and old password no longer works" do
    user = User.create!(email: @email, password: @password)
    raw_token = user.send_reset_password_instructions

    updated_user = UserAccountService.reset_password(token: raw_token, new_password: "newpassword456")
    assert_equal user.id, updated_user.id

    updated_user.reload
    assert updated_user.valid_password?("newpassword456"), "New password should work"
    assert_not updated_user.valid_password?(@password), "Old password should no longer work"
  end

  test "reset_password raises for invalid token" do
    assert_raises(ActiveRecord::RecordNotFound) do
      UserAccountService.reset_password(token: "invalid_token", new_password: "newpassword456")
    end
  end

  # === accept_invite ===

  test "accept_invite returns user with name and password set" do
    inviter = User.create!(email: "inviter2@test.com", password: "password123")
    invited = User.invite!({ email: @email }, inviter)
    raw_token = invited.raw_invitation_token

    user = UserAccountService.accept_invite(invitation_token: raw_token, password: @password, name: @name)
    assert user
    assert_equal @email, user.email
    assert_equal @name, user.name
    assert user.valid_password?(@password)
    assert user.invitation_accepted_at.present?
  end

  test "accept_invite returns nil for invalid token" do
    result = UserAccountService.accept_invite(invitation_token: "bad_token", password: @password, name: @name)
    assert_nil result
  end

  # === update_profile ===

  test "update_profile updates and persists user name" do
    user = User.create!(email: @email, password: @password, name: "Old Name")

    updated = UserAccountService.update_profile(user: user, attrs: { name: "New Name" })
    assert_equal "New Name", updated.name
    assert_equal "New Name", user.reload.name, "Name should be persisted to DB"
  end

  # === destroy_account ===

  test "destroy_account deletes user and orphaned instances" do
    user = User.create!(email: @email, password: @password)
    instance = Instance.create!(uri_scheme: "destroy#{SecureRandom.hex(4)}", api_key: SecureRandom.hex(32))
    InstanceRole.create!(role: "admin", instance_id: instance.id, user_id: user.id)

    assert_difference "User.count", -1 do
      UserAccountService.destroy_account(user: user)
    end

    assert_nil Instance.find_by(id: instance.id), "Orphaned instance should be destroyed"
    assert_equal 0, InstanceRole.where(user_id: user.id).count, "All roles should be removed"
  end

  test "destroy_account keeps instance when other admins exist" do
    user = User.create!(email: @email, password: @password)
    other_admin = User.create!(email: "otheradmin@test.com", password: "password123")
    instance = Instance.create!(uri_scheme: "keep#{SecureRandom.hex(4)}", api_key: SecureRandom.hex(32))
    InstanceRole.create!(role: "admin", instance_id: instance.id, user_id: user.id)
    InstanceRole.create!(role: "admin", instance_id: instance.id, user_id: other_admin.id)

    assert_difference "User.count", -1 do
      UserAccountService.destroy_account(user: user)
    end

    assert Instance.find_by(id: instance.id), "Instance should still exist with other admin"
    assert_equal 0, InstanceRole.where(user_id: user.id).count
    assert_equal 1, InstanceRole.where(instance_id: instance.id).count, "Other admin role should remain"
  end

  test "destroy_account with member role does not destroy instance" do
    user = User.create!(email: @email, password: @password)
    admin = User.create!(email: "admin_keep@test.com", password: "password123")
    instance = Instance.create!(uri_scheme: "memb#{SecureRandom.hex(4)}", api_key: SecureRandom.hex(32))
    InstanceRole.create!(role: "admin", instance_id: instance.id, user_id: admin.id)
    InstanceRole.create!(role: "member", instance_id: instance.id, user_id: user.id)

    UserAccountService.destroy_account(user: user)

    assert Instance.find_by(id: instance.id), "Instance should not be destroyed when user was only a member"
  end

  test "destroy_account revokes all oauth tokens" do
    user = User.create!(email: @email, password: @password)
    # Create a Doorkeeper app + token if possible
    app = Doorkeeper::Application.create!(name: "test", redirect_uri: "urn:ietf:wg:oauth:2.0:oob")
    Doorkeeper::AccessToken.create!(resource_owner_id: user.id, application_id: app.id, expires_in: 7200)
    assert_equal 1, Doorkeeper::AccessToken.where(resource_owner_id: user.id).count

    UserAccountService.destroy_account(user: user)
    assert_equal 0, Doorkeeper::AccessToken.where(resource_owner_id: user.id).count
  end

  test "destroy_account handles user with multiple instances" do
    user = User.create!(email: @email, password: @password)
    instance1 = Instance.create!(uri_scheme: "multi1#{SecureRandom.hex(3)}", api_key: SecureRandom.hex(32))
    instance2 = Instance.create!(uri_scheme: "multi2#{SecureRandom.hex(3)}", api_key: SecureRandom.hex(32))
    InstanceRole.create!(role: "admin", instance_id: instance1.id, user_id: user.id)
    InstanceRole.create!(role: "admin", instance_id: instance2.id, user_id: user.id)

    UserAccountService.destroy_account(user: user)

    assert_nil Instance.find_by(id: instance1.id), "First orphaned instance destroyed"
    assert_nil Instance.find_by(id: instance2.id), "Second orphaned instance destroyed"
  end


  # === setup_2fa ===

  test "setup_2fa generates otp_secret and returns provisioning URI with issuer" do
    user = User.create!(email: @email, password: @password)
    assert_nil user.otp_secret

    uri = UserAccountService.setup_2fa(user: user)
    assert uri.present?
    assert user.reload.otp_secret.present?
    assert uri.include?("Grovs"), "URI should contain the issuer"
    assert uri.start_with?("otpauth://"), "URI should be a valid OTP provisioning URI"
  end

  test "setup_2fa reuses existing otp_secret" do
    user = User.create!(email: @email, password: @password)
    user.update!(otp_secret: User.generate_otp_secret)
    original_secret = user.otp_secret

    UserAccountService.setup_2fa(user: user)
    assert_equal original_secret, user.reload.otp_secret
  end

  # Real AR-encrypted ciphertext JSON shape. In production this is what
  # `user.otp_secret` returns when keys drift and `support_unencrypted_data:
  # true` masks the decryption failure.
  GARBLED_CIPHERTEXT = '{"p":"iShx7TW8qBnvVHGcL04zXkTrFPZ5DPMI","h":{"iv":"s1VbhYHmzbL/g1J4","at":"jqIc4emsBN3XNvjY7u36ig=="}}'.freeze

  test "setup_2fa replaces a corrupted otp_secret with a valid Base32 value" do
    user = User.create!(email: @email, password: @password)
    corrupt_otp_secret!(user)

    UserAccountService.setup_2fa(user: user)
    user.reload

    assert_not_equal GARBLED_CIPHERTEXT, user.otp_secret, "Corrupted secret must be replaced"
    assert_match(/\A[A-Z2-7]+=*\z/, user.otp_secret, "Replacement must be valid Base32")
  end

  test "setup_2fa does not disable 2FA while recovering from a corrupted secret" do
    user = User.create!(email: @email, password: @password)
    user.update!(otp_required_for_login: true)
    corrupt_otp_secret!(user)

    UserAccountService.setup_2fa(user: user)

    assert user.reload.otp_required_for_login,
      "setup_2fa must not flip otp_required_for_login — a user mid-recovery must stay enrolled"
  end

  test "setup_2fa returns a well-formed otpauth URI with issuer, host, and embedded Base32 secret" do
    user = User.create!(email: @email, password: @password)
    corrupt_otp_secret!(user)

    uri = UserAccountService.setup_2fa(user: user)
    user.reload

    parsed = URI.parse(uri)
    assert_equal "otpauth", parsed.scheme, "URI scheme must be otpauth"
    assert_equal "totp", parsed.host, "URI type must be totp"

    query = URI.decode_www_form(parsed.query).to_h
    assert_equal "Grovs", query["issuer"], "URI must carry the configured issuer"
    assert_equal user.otp_secret, query["secret"], "URI must embed the saved secret verbatim"
    assert_match(/\A[A-Z2-7]+=*\z/, query["secret"], "Embedded secret must be Base32")
  end

  test "setup_2fa enables a full server-side TOTP round-trip after recovery" do
    user = User.create!(email: @email, password: @password)
    corrupt_otp_secret!(user)

    UserAccountService.setup_2fa(user: user)
    user.reload

    # The real contract: after recovery, ROTP must be able to both GENERATE
    # codes from the stored secret and VALIDATE them. If either side fails,
    # the enrollment UI shows "Wrong OTP code" and existing 2FA users are
    # permanently locked out.
    code = user.current_otp
    assert_match(/\A\d{6}\z/, code, "current_otp must produce a 6-digit numeric code")
    assert user.validate_and_consume_otp!(code),
      "Server must validate a code generated from its own stored secret"
  end

  test "setup_2fa URI is compatible with third-party TOTP apps (scanner → server)" do
    user = User.create!(email: @email, password: @password)
    corrupt_otp_secret!(user)

    uri = UserAccountService.setup_2fa(user: user)
    user.reload

    # Simulate what Google Authenticator does: parse the QR's otpauth URI,
    # extract the `secret` param, feed it to an *independent* ROTP instance,
    # generate a code, and have the server validate it. This catches URL-
    # encoding drift or any mismatch between the URI-embedded secret and the
    # server-side secret that a byte-equality assertion alone could miss
    # (e.g. if padding `=` got re-encoded somewhere in the chain).
    scanner_secret = URI.decode_www_form(URI.parse(uri).query).to_h.fetch("secret")
    scanner_code = ROTP::TOTP.new(scanner_secret).now

    assert user.validate_and_consume_otp!(scanner_code),
      "Server must accept codes generated from the URI-embedded secret by an independent authenticator"
  end

  private

  # Writes a Rails-encryption-shaped JSON blob to the user's otp_secret. This
  # simulates the service-layer symptom of AR encryption key drift: reading
  # `user.otp_secret` returns non-Base32 garbage that breaks ROTP everywhere
  # (enrollment validation, login validation, QR-code generation).
  def corrupt_otp_secret!(user)
    user.update!(otp_secret: GARBLED_CIPHERTEXT)
  end

  public

  # === toggle_2fa ===

  test "toggle_2fa returns nil for invalid OTP code without changing state" do
    user = User.create!(email: @email, password: @password)
    user.update!(otp_secret: User.generate_otp_secret)

    result = UserAccountService.toggle_2fa(user: user, enable: true, otp_code: "000000")
    assert_nil result
    assert_not user.reload.otp_required_for_login, "2FA should not be enabled with wrong code"
  end

  test "toggle_2fa enables 2FA with valid OTP code" do
    user = User.create!(email: @email, password: @password)
    user.update!(otp_secret: User.generate_otp_secret)

    valid_code = user.current_otp
    result = UserAccountService.toggle_2fa(user: user, enable: true, otp_code: valid_code)
    assert result
    assert_equal user.id, result.id
    assert user.reload.otp_required_for_login
  end

  test "toggle_2fa disables 2FA with valid OTP code" do
    user = User.create!(email: @email, password: @password)
    user.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true)
    assert user.otp_required_for_login

    valid_code = user.current_otp
    result = UserAccountService.toggle_2fa(user: user, enable: false, otp_code: valid_code)
    assert result
    assert_not user.reload.otp_required_for_login, "2FA should be disabled"
  end
end
