class IosPushConfiguration < ApplicationRecord
  belongs_to :ios_configuration

  encrypts :certificate_password

  after_create_commit :sync_rpush_app
  after_commit :clear_application_configuration_cache
  has_one_attached :certificate

  # Callbacks
  before_create :build_up
  before_destroy :cleanup_resources

  # Validations
  validate :certificate_must_be_attached
  validate :certificate_must_be_p8_extension

  private

  # Application#configuration caches the parent config for an hour; a push row changes what it serializes.
  def clear_application_configuration_cache
    ios_configuration&.application&.clear_configuration_cache
  end

  def certificate_must_be_attached
    errors.add(:certificate, 'must be attached') unless certificate.attached?
  end

  def certificate_must_be_p8_extension
    return unless certificate.attached?

    unless certificate.filename.to_s.end_with?('.p8')
      errors.add(:certificate, 'must be a .p8 file')
    end
  end

  # This method will ensure a unique name is assigned before saving the record
  def build_up
    # If the name is already present, skip generating a new one
    return if name.present?

    # Generate a unique name
    loop do
      self.name = "ios_config_#{SecureRandom.hex(10)}"
      break unless IosPushConfiguration.exists?(name: name)
    end
  end

  def sync_rpush_app
    RpushService.update_ios_rpush_app(id)
  end

  def cleanup_resources
    certificate.purge if certificate.attached?
    Rails.logger.info "Cleaning up IosPushConfiguration with ID #{id} before destroying."

    instance = ios_configuration.application&.instance
    if instance
      test = instance.test
      production = instance.production

      RpushService.remove_app(RpushService.app_for_platform(Grovs::Platforms::IOS, test))
      RpushService.remove_app(RpushService.app_for_platform(Grovs::Platforms::IOS, production))
    end
  end
end
