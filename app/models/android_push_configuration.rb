class AndroidPushConfiguration < ApplicationRecord
  belongs_to :android_configuration

  after_create_commit :sync_rpush_app
  has_one_attached :certificate

  # Callbacks
  before_create :build_up
  before_destroy :cleanup_resources

  # Validations
  validate :certificate_must_be_attached
  validate :certificate_must_be_json_extension

  private

  def certificate_must_be_attached
    errors.add(:certificate, 'must be attached') unless certificate.attached?
  end

  def certificate_must_be_json_extension
    return unless certificate.attached?

    unless certificate.filename.to_s.end_with?('.json')
      errors.add(:certificate, 'must be a JSON file (.json)')
    end
  end

  # This method will ensure a unique name is assigned before saving the record
  def build_up
    # If the name is already present, skip generating a new one
    return if name.present?

    # Generate a unique name
    loop do
      self.name = "android_config_#{SecureRandom.hex(10)}"
      break unless AndroidPushConfiguration.exists?(name: name)
    end
  end

  def sync_rpush_app
    RpushService.update_android_rpush_app(id)
  end

  # This method will handle any cleanup necessary before destroying the record
  def cleanup_resources
    # Example of cleanup logic, modify as needed
    # For instance, you can delete the attached certificate
    certificate.purge if certificate.attached?
      
    # Additional cleanup logic (if needed) can go here
    Rails.logger.info "Cleaning up AndroidPushConfiguration with ID #{id} before destroying."

    instance = android_configuration.application&.instance
    if instance
      test = instance.test
      production = instance.production

      test_app = RpushService.app_for_platform(Grovs::Platforms::ANDROID, test)
      if test_app
        test_app.destroy
      end

      prod_app = RpushService.app_for_platform(Grovs::Platforms::ANDROID, production)
      if prod_app
        prod_app.destroy
      end
    end
  end
end
