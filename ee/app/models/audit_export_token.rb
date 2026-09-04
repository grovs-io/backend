class AuditExportToken < ApplicationRecord
  include Hashid::Rails

  belongs_to :instance
  # The creator may delete their account later; the token (and its audit row) outlive them.
  belongs_to :created_by_user, class_name: "User", optional: true

  validates :name, presence: true, length: { maximum: 255 }
  validates :token_digest, presence: true, uniqueness: true

  scope :active, -> { where(revoked_at: nil) }

  # SIEM pollers cannot rotate credentials on a schedule, so tokens never expire; revocation is the control.
  def generate_token
    plain = "aet_#{SecureRandom.hex(32)}"
    self.token_digest = Digest::SHA256.hexdigest(plain)
    plain
  end

  def self.find_by_plain_token(plain)
    return nil if plain.blank?

    active.find_by(token_digest: Digest::SHA256.hexdigest(plain))
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def touch_last_used!
    update_column(:last_used_at, Time.current)
  end
end
