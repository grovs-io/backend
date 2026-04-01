class IosServerApiKey < ApplicationRecord
  belongs_to :ios_configuration

  encrypts :private_key

  validates :private_key, presence: true
  validates :key_id, presence: true
  validates :issuer_id, presence: true
  validate :private_key_must_be_valid_pem

  private

  def private_key_must_be_valid_pem
    return if private_key.blank?

    unless private_key.strip.start_with?('-----BEGIN PRIVATE KEY-----')
      errors.add(:private_key, 'must be a valid PKCS#8 private key (.p8 file)')
    end
  end
end
