require "test_helper"

class PlatformConfigurationServiceTest < ActiveSupport::TestCase
  VALID_P8_KEY = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg\n-----END PRIVATE KEY-----".freeze
  VALID_SERVICE_ACCOUNT_JSON = { type: "service_account", project_id: "test" }.to_json.freeze

  fixtures :instances, :projects

  setup do
    @instance = instances(:one)
    # Override application_for_platform to bypass Redis cache entirely.
    # The shared Redis cache causes stale entries across parallel test processes
    # because test transactions roll back but Redis persists.
    @instance.define_singleton_method(:application_for_platform) do |platform|
      app = Application.find_by(instance_id: id, platform: platform)
      app || Application.create!(instance_id: id, platform: platform)
    end
  end

  # Helper to create an uploaded file backed by a real Tempfile (not StringIO)
  # so ActiveStorage's attach works correctly
  def make_upload(content, content_type, filename)
    ext = File.extname(filename)
    base = File.basename(filename, ext)
    file = Tempfile.new([base, ext])
    file.binmode
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, content_type, false, original_filename: filename)
  end

  # === set_configuration ===

  test "set_configuration creates new iOS config when none exists" do
    RpushService.stub(:update_ios_rpush_app, true) do
      app = PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::IOS, enabled: true,
        config_params: { bundle_id: "com.test.app", app_prefix: "ABC123" }
      )

      assert app.persisted?
      assert app.enabled

      config = app.ios_configuration
      assert config
      assert_equal "com.test.app", config.bundle_id
      assert_equal "ABC123", config.app_prefix
    end
  end

  test "set_configuration updates existing iOS config" do
    RpushService.stub(:update_ios_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::IOS, enabled: true,
        config_params: { bundle_id: "com.test.app", app_prefix: "ABC123" }
      )

      app = PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::IOS, enabled: false,
        config_params: { bundle_id: "com.test.app2", app_prefix: "DEF456" }
      )

      assert_not app.enabled
      assert_equal "com.test.app2", app.ios_configuration.bundle_id
      assert_equal "DEF456", app.ios_configuration.app_prefix
    end
  end

  test "set_configuration creates Android config" do
    RpushService.stub(:update_android_rpush_app, true) do
      app = PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::ANDROID, enabled: true,
        config_params: { identifier: "com.test.android" }
      )

      assert app.persisted?
      config = app.android_configuration
      assert config
      assert_equal "com.test.android", config.identifier
    end
  end

  test "set_configuration creates Desktop config" do
    app = PlatformConfigurationService.set_configuration(
      instance: @instance, platform: Grovs::Platforms::DESKTOP, enabled: true,
      config_params: { fallback_url: "https://example.com" }
    )

    assert app.persisted?
    config = app.desktop_configuration
    assert config
    assert_equal "https://example.com", config.fallback_url
  end

  test "set_configuration does not call rpush for Desktop" do
    # No stub needed for RpushHelper — if it's called, it would error
    app = PlatformConfigurationService.set_configuration(
      instance: @instance, platform: Grovs::Platforms::DESKTOP, enabled: true,
      config_params: { fallback_url: "https://example.com" }
    )
    assert app.persisted?
  end

  # === set_ios_push_configuration ===

  test "set_ios_push_configuration creates push config with cert and password" do
    RpushService.stub(:update_ios_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::IOS, enabled: true,
        config_params: { bundle_id: "com.test.app", app_prefix: "ABC123" }
      )
    end

    cert_file = make_upload(VALID_P8_KEY, "application/octet-stream", "AuthKey.p8")

    RpushService.stub(:update_ios_rpush_app, true) do
      app = PlatformConfigurationService.set_ios_push_configuration(
        instance: @instance,
        certificate_params: { push_certificate_password: "secret", push_certificate: cert_file }
      )

      assert app.persisted?
      ios_config = app.ios_configuration
      assert ios_config.ios_push_configuration, "Push configuration should be created"
      assert_equal "secret", ios_config.ios_push_configuration.certificate_password
    end
  end

  test "set_ios_push_configuration destroys old push config before creating new" do
    RpushService.stub(:update_ios_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::IOS, enabled: true,
        config_params: { bundle_id: "com.test.app", app_prefix: "ABC123" }
      )
    end

    RpushService.stub(:update_ios_rpush_app, true) do
      cert_file1 = make_upload(VALID_P8_KEY, "application/octet-stream", "AuthKey1.p8")
      PlatformConfigurationService.set_ios_push_configuration(
        instance: @instance,
        certificate_params: { push_certificate_password: "pass1", push_certificate: cert_file1 }
      )

      cert_file2 = make_upload(VALID_P8_KEY, "application/octet-stream", "AuthKey2.p8")
      app = PlatformConfigurationService.set_ios_push_configuration(
        instance: @instance,
        certificate_params: { push_certificate_password: "pass2", push_certificate: cert_file2 }
      )

      ios_config = app.ios_configuration
      assert_equal "pass2", ios_config.ios_push_configuration.certificate_password
      assert_equal 1, IosPushConfiguration.where(ios_configuration_id: ios_config.id).count
    end
  end

  test "set_ios_push_configuration skips creation when password missing" do
    RpushService.stub(:update_ios_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::IOS, enabled: true,
        config_params: { bundle_id: "com.test.app", app_prefix: "ABC123" }
      )
    end

    cert_file = make_upload(VALID_P8_KEY, "application/octet-stream", "AuthKey.p8")
    app = PlatformConfigurationService.set_ios_push_configuration(
      instance: @instance,
      certificate_params: { push_certificate_password: nil, push_certificate: cert_file }
    )

    assert_nil app.ios_configuration.ios_push_configuration
  end

  # === set_android_push_configuration ===

  test "set_android_push_configuration creates push config" do
    RpushService.stub(:update_android_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::ANDROID, enabled: true,
        config_params: { identifier: "com.test.android" }
      )
    end

    cert_file = make_upload(VALID_SERVICE_ACCOUNT_JSON, "application/json", "service.json")
    RpushService.stub(:update_android_rpush_app, true) do
      app = PlatformConfigurationService.set_android_push_configuration(
        instance: @instance,
        certificate_params: { firebase_project_id: "my-project", push_certificate: cert_file }
      )

      assert app.persisted?
      android_config = app.android_configuration
      assert android_config.android_push_configuration
      assert_equal "my-project", android_config.android_push_configuration.firebase_project_id
    end
  end

  test "set_android_push_configuration destroys old push config" do
    RpushService.stub(:update_android_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::ANDROID, enabled: true,
        config_params: { identifier: "com.test.android" }
      )
    end

    RpushService.stub(:update_android_rpush_app, true) do
      cert1 = make_upload(VALID_SERVICE_ACCOUNT_JSON, "application/json", "s1.json")
      PlatformConfigurationService.set_android_push_configuration(
        instance: @instance,
        certificate_params: { firebase_project_id: "proj1", push_certificate: cert1 }
      )

      cert2 = make_upload(VALID_SERVICE_ACCOUNT_JSON, "application/json", "s2.json")
      app = PlatformConfigurationService.set_android_push_configuration(
        instance: @instance,
        certificate_params: { firebase_project_id: "proj2", push_certificate: cert2 }
      )

      android_config = app.android_configuration
      assert_equal "proj2", android_config.android_push_configuration.firebase_project_id
      assert_equal 1, AndroidPushConfiguration.where(android_configuration_id: android_config.id).count
    end
  end

  test "set_android_push_configuration skips creation when firebase_project_id missing" do
    RpushService.stub(:update_android_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::ANDROID, enabled: true,
        config_params: { identifier: "com.test.android" }
      )
    end

    cert = make_upload(VALID_SERVICE_ACCOUNT_JSON, "application/json", "s.json")
    app = PlatformConfigurationService.set_android_push_configuration(
      instance: @instance,
      certificate_params: { firebase_project_id: nil, push_certificate: cert }
    )

    assert_nil app.android_configuration.android_push_configuration
  end

  # === set_android_api_access_key ===

  test "set_android_api_access_key raises when no Android config" do
    # Ensure no android configuration exists for this instance
    app = Application.find_by(instance_id: @instance.id, platform: Grovs::Platforms::ANDROID)
    app&.android_configuration&.destroy
    assert_raises ArgumentError do
      PlatformConfigurationService.set_android_api_access_key(
        instance: @instance, key_params: { file: nil }
      )
    end
  end

  test "set_android_api_access_key creates key with file" do
    RpushService.stub(:update_android_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::ANDROID, enabled: true,
        config_params: { identifier: "com.test.android" }
      )
    end

    file = make_upload(VALID_SERVICE_ACCOUNT_JSON, "application/json", "key.json")
    app = PlatformConfigurationService.set_android_api_access_key(
      instance: @instance, key_params: { file: file }
    )

    assert app.android_configuration.android_server_api_key
  end

  test "set_android_api_access_key destroys old key before creating new" do
    RpushService.stub(:update_android_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::ANDROID, enabled: true,
        config_params: { identifier: "com.test.android" }
      )
    end

    file1 = make_upload(VALID_SERVICE_ACCOUNT_JSON, "application/json", "key1.json")
    PlatformConfigurationService.set_android_api_access_key(
      instance: @instance, key_params: { file: file1 }
    )

    file2 = make_upload(VALID_SERVICE_ACCOUNT_JSON, "application/json", "key2.json")
    app = PlatformConfigurationService.set_android_api_access_key(
      instance: @instance, key_params: { file: file2 }
    )

    android_config = app.android_configuration
    assert_equal 1, AndroidServerApiKey.where(android_configuration_id: android_config.id).count
  end

  test "set_android_api_access_key skips creation when file is nil" do
    RpushService.stub(:update_android_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::ANDROID, enabled: true,
        config_params: { identifier: "com.test.android" }
      )
    end

    app = PlatformConfigurationService.set_android_api_access_key(
      instance: @instance, key_params: { file: nil }
    )

    assert_nil app.android_configuration.android_server_api_key
  end

  # === set_ios_api_access_key ===

  test "set_ios_api_access_key creates key with all params" do
    RpushService.stub(:update_ios_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::IOS, enabled: true,
        config_params: { bundle_id: "com.test.app", app_prefix: "ABC123" }
      )
    end

    file = make_upload(VALID_P8_KEY, "text/plain", "AuthKey.p8")
    app = PlatformConfigurationService.set_ios_api_access_key(
      instance: @instance,
      key_params: { file: file, key_id: "KEY123", issuer_id: "ISSUER456" }
    )

    ios_config = app.ios_configuration
    key = ios_config.ios_server_api_key
    assert key, "iOS server API key should be created"
    assert_equal "KEY123", key.key_id
    assert_equal "ISSUER456", key.issuer_id
    assert_equal VALID_P8_KEY, key.private_key
    assert_equal "AuthKey.p8", key.filename
  end

  test "set_ios_api_access_key destroys old key before creating new" do
    RpushService.stub(:update_ios_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::IOS, enabled: true,
        config_params: { bundle_id: "com.test.app", app_prefix: "ABC123" }
      )
    end

    file1 = make_upload(VALID_P8_KEY, "text/plain", "k1.p8")
    PlatformConfigurationService.set_ios_api_access_key(
      instance: @instance,
      key_params: { file: file1, key_id: "K1", issuer_id: "I1" }
    )

    file2 = make_upload(VALID_P8_KEY, "text/plain", "k2.p8")
    app = PlatformConfigurationService.set_ios_api_access_key(
      instance: @instance,
      key_params: { file: file2, key_id: "K2", issuer_id: "I2" }
    )

    ios_config = app.ios_configuration
    assert_equal "K2", ios_config.ios_server_api_key.key_id
    assert_equal 1, IosServerApiKey.where(ios_configuration_id: ios_config.id).count
  end

  test "set_ios_api_access_key skips creation when key_id missing" do
    RpushService.stub(:update_ios_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::IOS, enabled: true,
        config_params: { bundle_id: "com.test.app", app_prefix: "ABC123" }
      )
    end

    file = make_upload(VALID_P8_KEY, "text/plain", "k.p8")
    app = PlatformConfigurationService.set_ios_api_access_key(
      instance: @instance,
      key_params: { file: file, key_id: nil, issuer_id: "I1" }
    )

    assert_nil app.ios_configuration.ios_server_api_key
  end

  # === file content validation ===

  test "set_android_api_access_key raises for non-JSON file" do
    RpushService.stub(:update_android_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::ANDROID, enabled: true,
        config_params: { identifier: "com.test.android" }
      )
    end

    file = make_upload("not json", "text/plain", "key.txt")
    error = assert_raises(ArgumentError) do
      PlatformConfigurationService.set_android_api_access_key(
        instance: @instance, key_params: { file: file }
      )
    end
    assert_equal "File must be a JSON file (.json)", error.message
  end

  test "set_android_api_access_key raises for invalid JSON content" do
    RpushService.stub(:update_android_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::ANDROID, enabled: true,
        config_params: { identifier: "com.test.android" }
      )
    end

    file = make_upload("{ broken json", "application/json", "key.json")
    error = assert_raises(ArgumentError) do
      PlatformConfigurationService.set_android_api_access_key(
        instance: @instance, key_params: { file: file }
      )
    end
    assert_equal "File must contain valid JSON", error.message
  end

  test "set_android_api_access_key raises for JSON without service_account type" do
    RpushService.stub(:update_android_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::ANDROID, enabled: true,
        config_params: { identifier: "com.test.android" }
      )
    end

    file = make_upload({ type: "not_service_account" }.to_json, "application/json", "key.json")
    error = assert_raises(ArgumentError) do
      PlatformConfigurationService.set_android_api_access_key(
        instance: @instance, key_params: { file: file }
      )
    end
    assert_equal "File must be a valid Google service account JSON file", error.message
  end

  test "set_android_push_configuration raises for invalid JSON content" do
    RpushService.stub(:update_android_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::ANDROID, enabled: true,
        config_params: { identifier: "com.test.android" }
      )
    end

    cert = make_upload("{ broken", "application/json", "s.json")
    error = assert_raises(ArgumentError) do
      PlatformConfigurationService.set_android_push_configuration(
        instance: @instance,
        certificate_params: { firebase_project_id: "proj", push_certificate: cert }
      )
    end
    assert_equal "File must contain valid JSON", error.message
  end

  test "set_ios_push_configuration raises for non-p8 file" do
    RpushService.stub(:update_ios_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::IOS, enabled: true,
        config_params: { bundle_id: "com.test.app", app_prefix: "ABC123" }
      )
    end

    cert_file = make_upload("cert data", "application/octet-stream", "cert.pem")
    error = assert_raises(ArgumentError) do
      PlatformConfigurationService.set_ios_push_configuration(
        instance: @instance,
        certificate_params: { push_certificate_password: "secret", push_certificate: cert_file }
      )
    end
    assert_equal "File must be a .p8 file", error.message
  end

  test "set_ios_push_configuration raises for p8 without PEM header" do
    RpushService.stub(:update_ios_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::IOS, enabled: true,
        config_params: { bundle_id: "com.test.app", app_prefix: "ABC123" }
      )
    end

    cert_file = make_upload("not a private key", "application/octet-stream", "AuthKey.p8")
    error = assert_raises(ArgumentError) do
      PlatformConfigurationService.set_ios_push_configuration(
        instance: @instance,
        certificate_params: { push_certificate_password: "secret", push_certificate: cert_file }
      )
    end
    assert_equal "File must be a valid PKCS#8 private key (.p8)", error.message
  end

  test "set_ios_api_access_key raises for non-p8 file" do
    RpushService.stub(:update_ios_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::IOS, enabled: true,
        config_params: { bundle_id: "com.test.app", app_prefix: "ABC123" }
      )
    end

    file = make_upload(VALID_P8_KEY, "text/plain", "key.txt")
    error = assert_raises(ArgumentError) do
      PlatformConfigurationService.set_ios_api_access_key(
        instance: @instance,
        key_params: { file: file, key_id: "K1", issuer_id: "I1" }
      )
    end
    assert_equal "File must be a .p8 file", error.message
  end

  test "set_ios_api_access_key raises for p8 without PEM header" do
    RpushService.stub(:update_ios_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::IOS, enabled: true,
        config_params: { bundle_id: "com.test.app", app_prefix: "ABC123" }
      )
    end

    file = make_upload("not a key", "text/plain", "AuthKey.p8")
    error = assert_raises(ArgumentError) do
      PlatformConfigurationService.set_ios_api_access_key(
        instance: @instance,
        key_params: { file: file, key_id: "K1", issuer_id: "I1" }
      )
    end
    assert_equal "File must be a valid PKCS#8 private key (.p8)", error.message
  end

  # === set_web_configuration ===

  test "set_web_configuration creates web config with domains" do
    app = PlatformConfigurationService.set_web_configuration(
      instance: @instance, enabled: true,
      config_params: { domains: ["example.com", "test.com"] }
    )

    assert app.persisted?
    web_config = WebConfiguration.find_by(application_id: app.id)
    assert web_config
    assert_equal 2, web_config.web_configuration_linked_domains.count
    domains = web_config.web_configuration_linked_domains.pluck(:domain)
    assert_includes domains, "example.com"
    assert_includes domains, "test.com"
  end

  test "set_web_configuration replaces existing domains" do
    app = PlatformConfigurationService.set_web_configuration(
      instance: @instance, enabled: true,
      config_params: { domains: ["old.com"] }
    )

    web_config = WebConfiguration.find_by(application_id: app.id)
    assert_equal 1, web_config.web_configuration_linked_domains.count

    app = PlatformConfigurationService.set_web_configuration(
      instance: @instance, enabled: true,
      config_params: { domains: ["new1.com", "new2.com"] }
    )

    web_config.reload
    assert_equal 2, web_config.web_configuration_linked_domains.count
    domains = web_config.web_configuration_linked_domains.pluck(:domain)
    assert_not_includes domains, "old.com"
    assert_includes domains, "new1.com"
  end

  test "set_web_configuration with empty domains array clears all domains" do
    PlatformConfigurationService.set_web_configuration(
      instance: @instance, enabled: true,
      config_params: { domains: ["old.com"] }
    )

    app = PlatformConfigurationService.set_web_configuration(
      instance: @instance, enabled: true,
      config_params: { domains: [] }
    )

    web_config = WebConfiguration.find_by(application_id: app.id)
    assert_equal 0, web_config.web_configuration_linked_domains.count
  end

  test "set_web_configuration with nil domains creates no domains" do
    app = PlatformConfigurationService.set_web_configuration(
      instance: @instance, enabled: true,
      config_params: {}
    )

    web_config = WebConfiguration.find_by(application_id: app.id)
    assert web_config, "WebConfiguration should be persisted even with no domains"
    assert_equal 0, web_config.web_configuration_linked_domains.count
  end

  # === remove_configuration ===

  test "remove_configuration destroys iOS config and cascading push config" do
    RpushService.stub(:update_ios_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::IOS, enabled: true,
        config_params: { bundle_id: "com.test.app", app_prefix: "ABC123" }
      )

      cert_file = make_upload(VALID_P8_KEY, "application/octet-stream", "AuthKey.p8")
      PlatformConfigurationService.set_ios_push_configuration(
        instance: @instance,
        certificate_params: { push_certificate_password: "secret", push_certificate: cert_file }
      )
    end

    app = Application.find_by(instance_id: @instance.id, platform: Grovs::Platforms::IOS)
    ios_config_id = app.ios_configuration.id
    assert IosPushConfiguration.exists?(ios_configuration_id: ios_config_id), "Push config should exist before remove"

    PlatformConfigurationService.remove_configuration(instance: @instance, platform: Grovs::Platforms::IOS)

    assert_not IosConfiguration.exists?(ios_config_id), "iOS config should be destroyed"
    assert_not IosPushConfiguration.exists?(ios_configuration_id: ios_config_id), "Push config should be cascade-destroyed"
  end

  test "remove_configuration destroys Android config and cascading push config" do
    RpushService.stub(:update_android_rpush_app, true) do
      PlatformConfigurationService.set_configuration(
        instance: @instance, platform: Grovs::Platforms::ANDROID, enabled: true,
        config_params: { identifier: "com.test.android" }
      )

      cert_file = make_upload(VALID_SERVICE_ACCOUNT_JSON, "application/json", "service.json")
      PlatformConfigurationService.set_android_push_configuration(
        instance: @instance,
        certificate_params: { firebase_project_id: "my-project", push_certificate: cert_file }
      )
    end

    app = Application.find_by(instance_id: @instance.id, platform: Grovs::Platforms::ANDROID)
    android_config_id = app.android_configuration.id
    assert AndroidPushConfiguration.exists?(android_configuration_id: android_config_id)

    PlatformConfigurationService.remove_configuration(instance: @instance, platform: Grovs::Platforms::ANDROID)

    assert_not AndroidConfiguration.exists?(android_config_id), "Android config should be destroyed"
    assert_not AndroidPushConfiguration.exists?(android_configuration_id: android_config_id), "Push config should be cascade-destroyed"
  end

  test "remove_configuration destroys Desktop config" do
    PlatformConfigurationService.set_configuration(
      instance: @instance, platform: Grovs::Platforms::DESKTOP, enabled: true,
      config_params: { fallback_url: "https://example.com" }
    )

    app = Application.find_by(instance_id: @instance.id, platform: Grovs::Platforms::DESKTOP)
    desktop_config_id = app.desktop_configuration.id

    PlatformConfigurationService.remove_configuration(instance: @instance, platform: Grovs::Platforms::DESKTOP)

    assert_not DesktopConfiguration.exists?(desktop_config_id), "Desktop config should be destroyed"
  end

  test "remove_configuration is a no-op when no config exists" do
    fresh_instance = instances(:two)
    fresh_instance.define_singleton_method(:application_for_platform) do |platform|
      app = Application.find_by(instance_id: id, platform: platform)
      app || Application.create!(instance_id: id, platform: platform)
    end

    assert_nothing_raised do
      PlatformConfigurationService.remove_configuration(instance: fresh_instance, platform: Grovs::Platforms::IOS)
    end
  end

  # === remove_web_configuration ===

  test "remove_web_configuration destroys web config and linked domains" do
    PlatformConfigurationService.set_web_configuration(
      instance: @instance, enabled: true,
      config_params: { domains: ["example.com", "test.com"] }
    )

    app = Application.find_by(instance_id: @instance.id, platform: Grovs::Platforms::WEB)
    web_config_id = app.web_configuration.id
    assert_equal 2, WebConfigurationLinkedDomain.where(web_configuration_id: web_config_id).count

    PlatformConfigurationService.remove_web_configuration(instance: @instance)

    assert_not WebConfiguration.exists?(web_config_id), "Web config should be destroyed"
    assert_equal 0, WebConfigurationLinkedDomain.where(web_configuration_id: web_config_id).count,
      "Linked domains should be cascade-destroyed"
  end

  test "remove_web_configuration is a no-op when no config exists" do
    fresh_instance = instances(:two)
    fresh_instance.define_singleton_method(:application_for_platform) do |platform|
      app = Application.find_by(instance_id: id, platform: platform)
      app || Application.create!(instance_id: id, platform: platform)
    end

    assert_nothing_raised do
      PlatformConfigurationService.remove_web_configuration(instance: fresh_instance)
    end
  end
end
