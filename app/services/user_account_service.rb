class UserAccountService
  # Registers a new user or accepts a pending invitation.
  # Returns the User record.
  def self.register(email:, password:, name:)
    user = User.find_by(email: email)

    if user
      if user.invitation_token.present? && user.invitation_accepted_at.nil?
        user.password = password
        user.name = name
        user.save!
        user.update(invitation_accepted_at: Time.current, invitation_token: nil)
      else
        raise ArgumentError, "An account with this email already exists"
      end
    else
      user = User.create!(email: email, password: password, name: name)
      WelcomeMailer.welcome(user).deliver_later
    end

    user
  end

  # Sends Devise reset_password_instructions.
  # Returns the User or nil if not found.
  def self.request_password_reset(email:)
    user = User.find_by(email: email)
    return nil unless user

    user.send_reset_password_instructions
    user
  end

  # Resets password using Devise token.
  # Returns User or raises if token is invalid.
  def self.reset_password(token:, new_password:)
    digested = Devise.token_generator.digest(User, :reset_password_token, token)
    user = User.find_by(reset_password_token: digested)
    raise ActiveRecord::RecordNotFound, "Invalid data" unless user

    user.update!(password: new_password)
    user
  end

  # Accepts a Devise invitation.
  # Returns User or nil if token invalid.
  def self.accept_invite(invitation_token:, password:, name:)
    user = User.find_by_invitation_token(invitation_token, true)
    return nil unless user

    User.accept_invitation!(invitation_token: invitation_token, password: password, name: name)
  end

  # Updates user profile fields.
  # Returns User.
  def self.update_profile(user:, attrs:)
    user.update!(attrs)
    user
  end

  # Cascading delete: remove roles → destroy orphaned instances → revoke tokens → destroy user.
  def self.destroy_account(user:)
    roles = user.instance_roles.includes(:instance)

    roles.each do |role|
      instance = role.instance

      if role.role == "admin"
        other_admins = instance.instance_roles.where(role: "admin").where.not(user_id: user.id)
        instance.destroy! if other_admins.empty?
      end

      role.destroy!
    end

    Doorkeeper::AccessToken.where(resource_owner_id: user.id).destroy_all
    user.destroy!
  end


  # Generates OTP secret if needed, returns provisioning URI for QR code.
  def self.setup_2fa(user:)
    unless user.otp_secret
      user.otp_secret = User.generate_otp_secret
      user.save!
    end

    issuer = ENV.fetch("OTP_ISSUER", "Grovs")
    label = "#{issuer}:#{user.email}"
    user.otp_provisioning_uri(label, issuer: issuer)
  end

  # Validates OTP code and toggles 2FA on/off.
  # Returns User or nil if OTP code is invalid.
  def self.toggle_2fa(user:, enable:, otp_code:)
    user.otp_required_for_login = enable
    otp_valid = user.validate_and_consume_otp!(otp_code)
    return nil unless otp_valid

    user.save!
    user
  end
end
