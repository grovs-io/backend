class EventStreamToken < ApplicationRecord
  include Hashid::Rails

  belongs_to :project
  belongs_to :created_by_user, class_name: "User", optional: true

  validates :name, presence: true, length: { maximum: 255 }
  validates :token_digest, presence: true, uniqueness: true

  scope :active, -> { where(revoked_at: nil) }

  def generate_token
    plain = "est_#{SecureRandom.hex(32)}"
    self.token_digest = Digest::SHA256.hexdigest(plain)
    plain
  end

  def self.find_by_plain_token(plain)
    return nil if plain.blank?

    active.find_by(token_digest: Digest::SHA256.hexdigest(plain))
  end

  def revoke! = update!(revoked_at: Time.current)
  # A poller may read twice a second; this column only has to be accurate to the minute.
  def touch_last_used!
    return if last_used_at && last_used_at > 1.minute.ago

    update_column(:last_used_at, Time.current)
  end
end
