class AndroidServerApiKey < ApplicationRecord
  belongs_to :android_configuration
  has_one_attached :file

  # Validations
  validate :certificate_must_be_attached
  validate :file_must_be_json_extension

  private

  def certificate_must_be_attached
    errors.add(:file, 'must be attached') unless file.attached?
  end

  def file_must_be_json_extension
    return unless file.attached?

    unless file.filename.to_s.end_with?('.json')
      errors.add(:file, 'must be a JSON file (.json)')
    end
  end
end
