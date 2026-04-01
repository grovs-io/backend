class PlatformConfigurationService
  # Unified platform config set (iOS, Android, Desktop)
  # Returns the Application record
  def self.set_configuration(instance:, platform:, enabled:, config_params:)
    ActiveRecord::Base.transaction do
      application = instance.application_for_platform(platform)
      application.enabled = enabled
      application.save!

      config = find_or_create_config(application, platform, save: false)
      config.assign_attributes(config_params)
      config.save!

      update_rpush_if_needed(config, platform)

      application
    end
  end

  # Removes a platform configuration and its associated application.
  # Cascades: push config, API keys, cache cleared via after_destroy callbacks.
  def self.remove_configuration(instance:, platform:)
    ActiveRecord::Base.transaction do
      application = Application.find_by(instance_id: instance.id, platform: platform)
      return unless application

      config = existing_config(application, platform)
      config&.destroy!
    end
  end

  # iOS push cert upload
  def self.set_ios_push_configuration(instance:, certificate_params:)
    ActiveRecord::Base.transaction do
      application = instance.application_for_platform(Grovs::Platforms::IOS)
      application.save!

      ios_config = find_or_create_config(application, Grovs::Platforms::IOS)

      old_push = ios_config.ios_push_configuration
      if old_push
        old_push.destroy!
        ios_config.reload
      end

      password = certificate_params[:push_certificate_password]
      certificate = certificate_params[:push_certificate]

      if password && certificate
        content = validate_p8_file!(certificate)

        blob = ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(content),
          filename: certificate.original_filename,
          content_type: certificate.content_type || "application/octet-stream"
        )

        push = IosPushConfiguration.new
        push.certificate.attach(blob)
        push.certificate_password = password
        push.ios_configuration = ios_config
        push.save!
      end

      application
    end
  end

  # Android push cert upload
  def self.set_android_push_configuration(instance:, certificate_params:)
    ActiveRecord::Base.transaction do
      application = instance.application_for_platform(Grovs::Platforms::ANDROID)

      android_config = find_or_create_config(application, Grovs::Platforms::ANDROID)

      old_push = android_config.android_push_configuration
      if old_push
        old_push.destroy!
        android_config.reload
      end

      firebase_project_id = certificate_params[:firebase_project_id]
      certificate = certificate_params[:push_certificate]

      if firebase_project_id && certificate
        content = validate_service_account_json!(certificate)

        blob = ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(content),
          filename: certificate.original_filename,
          content_type: certificate.content_type || "application/octet-stream"
        )

        push = AndroidPushConfiguration.new
        push.certificate.attach(blob)
        push.firebase_project_id = firebase_project_id
        push.android_configuration = android_config
        push.save!
      end

      application
    end
  end

  # Android API key upload (ActiveStorage file)
  def self.set_android_api_access_key(instance:, key_params:)
    ActiveRecord::Base.transaction do
      application = instance.application_for_platform(Grovs::Platforms::ANDROID)

      android_config = application.android_configuration
      unless android_config
        raise ArgumentError, "Android configuration must be set up first"
      end

      old_key = android_config.android_server_api_key
      if old_key
        old_key.destroy!
        android_config.reload
      end

      file = key_params[:file]
      if file
        content = validate_service_account_json!(file)

        blob = ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(content),
          filename: file.original_filename,
          content_type: file.content_type || "application/octet-stream"
        )

        api_key = AndroidServerApiKey.new
        api_key.file.attach(blob)
        api_key.android_configuration = android_config
        api_key.save!
        application.reload
      end

      application
    end
  end

  # iOS API key upload (text column + key_id + issuer_id)
  def self.set_ios_api_access_key(instance:, key_params:)
    ActiveRecord::Base.transaction do
      application = instance.application_for_platform(Grovs::Platforms::IOS)

      ios_config = find_or_create_config(application, Grovs::Platforms::IOS)

      old_key = ios_config.ios_server_api_key
      if old_key
        old_key.destroy!
        ios_config.reload
      end

      file = key_params[:file]
      key_id = key_params[:key_id]
      issuer_id = key_params[:issuer_id]

      if file && key_id && issuer_id
        private_key_content = validate_p8_file!(file)

        api_key = IosServerApiKey.new
        api_key.private_key = private_key_content
        api_key.key_id = key_id
        api_key.issuer_id = issuer_id
        api_key.filename = file.original_filename
        api_key.ios_configuration = ios_config
        api_key.save!
        application.reload
      end

      application
    end
  end

  # Removes web configuration and its associated application.
  def self.remove_web_configuration(instance:)
    ActiveRecord::Base.transaction do
      application = Application.find_by(instance_id: instance.id, platform: Grovs::Platforms::WEB)
      return unless application

      web_config = application.web_configuration
      web_config&.destroy!
    end
  end

  # Web-specific (has linked domains array)
  def self.set_web_configuration(instance:, enabled:, config_params:)
    ActiveRecord::Base.transaction do
      application = instance.application_for_platform(Grovs::Platforms::WEB)
      application.enabled = enabled
      application.save!

      web_config = application.web_configuration
      unless web_config
        web_config = WebConfiguration.new
        web_config.application = application
        web_config.save!
      end

      web_config.web_configuration_linked_domains.destroy_all
      (config_params[:domains] || []).each do |domain|
        linked_domain = WebConfigurationLinkedDomain.new(domain: domain)
        linked_domain.web_configuration = web_config
        linked_domain.save!
      end

      web_config.clear_configuration_cache

      application.reload
    end
  end

  # Returns the rendered Google Cloud setup script with the push endpoint injected.
  def self.google_configuration_script(instance:)
    push_endpoint = "#{ENV['SERVER_HOST_PROTOCOL']}api.#{ENV['SERVER_HOST']}/api/v1/iap/google/#{instance.hashid}"

    template_path = Rails.root.join("app/templates/grovs_android_gcloud_setup.sh")
    script = File.read(template_path)
    script.gsub("{{PUSH_ENDPOINT}}", push_endpoint)
  end

  # When save: false, returns an unsaved record (caller must save after assigning attributes)
  private_class_method def self.find_or_create_config(application, platform, save: true)
    case platform
    when Grovs::Platforms::IOS
      config = application.ios_configuration
      unless config
        config = IosConfiguration.new
        config.application = application
        config.save! if save
      end
      config
    when Grovs::Platforms::ANDROID
      config = application.android_configuration
      unless config
        config = AndroidConfiguration.new
        config.application = application
        config.save! if save
      end
      config
    when Grovs::Platforms::DESKTOP
      config = application.desktop_configuration
      unless config
        config = DesktopConfiguration.new
        config.application = application
        config.save! if save
      end
      config
    end
  end

  # Validates and returns the file content (caller uses the returned content
  # instead of re-reading the uploaded file IO, avoiding rewind issues).
  private_class_method def self.validate_service_account_json!(file)
    filename = file.try(:original_filename) || file.try(:filename)&.to_s
    unless filename&.end_with?('.json')
      raise ArgumentError, "File must be a JSON file (.json)"
    end

    content = file.read
    parsed = JSON.parse(content)

    unless parsed.is_a?(Hash) && parsed['type'] == 'service_account'
      raise ArgumentError, "File must be a valid Google service account JSON file"
    end

    content
  rescue JSON::ParserError
    raise ArgumentError, "File must contain valid JSON"
  end

  private_class_method def self.validate_p8_file!(file)
    filename = file.try(:original_filename) || file.try(:filename)&.to_s
    unless filename&.end_with?('.p8')
      raise ArgumentError, "File must be a .p8 file"
    end

    content = file.read
    unless content.to_s.strip.start_with?('-----BEGIN PRIVATE KEY-----')
      raise ArgumentError, "File must be a valid PKCS#8 private key (.p8)"
    end

    content
  end

  private_class_method def self.existing_config(application, platform)
    case platform
    when Grovs::Platforms::IOS     then application.ios_configuration
    when Grovs::Platforms::ANDROID then application.android_configuration
    when Grovs::Platforms::DESKTOP then application.desktop_configuration
    end
  end

  private_class_method def self.update_rpush_if_needed(config, platform)
    case platform
    when Grovs::Platforms::IOS
      push = config.ios_push_configuration
      RpushService.update_ios_rpush_app(push.id) if push
    when Grovs::Platforms::ANDROID
      push = config.android_push_configuration
      RpushService.update_android_rpush_app(push.id) if push
    end
  end
end
