class User < ApplicationRecord
  devise :two_factor_authenticatable
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :invitable, :registerable,
         :recoverable, :rememberable, :validatable, :omniauthable, 
         omniauth_providers: [:google_oauth2, :microsoft_graph]

  validates :email, format: URI::MailTo::EMAIL_REGEXP

  has_many :instance_roles, dependent: :destroy
  has_many :instances, through: :instance_roles

  has_many :stripe_payment_intents

  # the authenticate method from devise documentation
  def self.authenticate(email, password, otp_code)
    user = User.find_for_authentication(email: email)
    return nil unless user&.valid_password?(password)

    if user.otp_required_for_login
      raise OtpRequiredError if otp_code.blank?
      return nil unless user.validate_and_consume_otp!(otp_code)
    end

    user
  end

  # Override to handle legacy encrypted otp_secret (pre devise-two-factor 6.0).
  # Old secrets are JSON-encoded and cause ROTP::Base32::Base32Error.
  def validate_and_consume_otp!(code, options = {})
    super
  rescue ROTP::Base32::Base32Error
    false
  end

  # Overwritten

  def password_required?
    # Skip validation in specific circumstances (like invitation, OAuth, etc.)
    # For example, skip validation if the user has OAuth
    return false if provider.present?
    
    # Otherwise use Devise's default behavior
    super
  end

  # Methods
  
  def instance_roles_as_array
    instance_roles.map { |ir| { instance_id: ir.instance_id, role: ir.role } }
  end

  def admin?(instance)
    unless instance
      return false
    end

    user_role = InstanceRole.role_for_user_and_instance(self, instance)
    unless user_role
      return false
    end

    user_role.role == "admin"
  end

end
