require "test_helper"

class RpushServiceTest < ActiveSupport::TestCase
  VALID_P8_KEY = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg\n-----END PRIVATE KEY-----".freeze
  VALID_SERVICE_ACCOUNT_JSON = { type: "service_account", project_id: "test" }.to_json.freeze

  fixtures :instances, :projects, :applications, :ios_configurations,
           :android_configurations, :ios_push_configurations,
           :android_push_configurations, :devices, :visitors

  setup do
    @instance = instances(:one)
    @project = projects(:one)
    @ios_app = applications(:ios_app)
    @android_app = applications(:android_app)
    @ios_config = ios_configurations(:one)
    @android_config = android_configurations(:one)
  end

  teardown do
    Rpush::Apnsp8::App.delete_all
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Fcm::App.delete_all
    Rpush::Fcm::Notification.delete_all
  end


  test "app_for_platform returns nil when project is nil" do
    result = RpushService.app_for_platform(Grovs::Platforms::IOS, nil)
    assert_nil result
  end

  test "app_for_platform returns nil when instance has no application for platform" do
    # instance two has no android application in fixtures (only second_ios_app)
    project_two = projects(:two)
    result = RpushService.app_for_platform(Grovs::Platforms::ANDROID, project_two)
    assert_nil result
  end

  test "app_for_platform returns nil when ios application has no configuration" do
    # Temporarily remove the ios_configuration association
    @ios_config.destroy!

    result = RpushService.app_for_platform(Grovs::Platforms::IOS, @project)
    assert_nil result
  end

  test "app_for_platform returns nil when ios configuration has no push configuration" do
    # Destroy fixture push config so ios_config has no push configuration
    @ios_config.ios_push_configuration&.destroy!
    @ios_config.reload
    assert_nil @ios_config.ios_push_configuration
    result = RpushService.app_for_platform(Grovs::Platforms::IOS, @project)
    assert_nil result
  end

  test "app_for_platform returns nil when android configuration has no push configuration" do
    # Destroy fixture push config so android_config has no push configuration
    @android_config.android_push_configuration&.destroy!
    @android_config.reload
    assert_nil @android_config.android_push_configuration
    result = RpushService.app_for_platform(Grovs::Platforms::ANDROID, @project)
    assert_nil result
  end

  test "app_for_platform returns rpush app for ios when full chain exists" do
    # Remove fixture push config so we can create our own
    @ios_config.ios_push_configuration&.destroy!

    push_config = IosPushConfiguration.new(
      ios_configuration: @ios_config,
      name: "test_ios_push",
      certificate_password: "key123"
    )
    push_config.certificate.attach(
      io: StringIO.new(VALID_P8_KEY),
      filename: "AuthKey.p8",
      content_type: "application/octet-stream"
    )
    RpushService.stub(:update_ios_rpush_app, nil) do
      push_config.save!
    end

    # project.test defaults to false, so the app name should be "test_ios_push-production"
    rpush_app = Rpush::Apnsp8::App.new
    rpush_app.name = "test_ios_push-production"
    rpush_app.apn_key = "fake-key"
    rpush_app.environment = "production"
    rpush_app.apn_key_id = "key123"
    rpush_app.team_id = "ABC123"
    rpush_app.bundle_id = "com.test.iosapp"
    rpush_app.connections = 1
    rpush_app.save!

    result = RpushService.app_for_platform(Grovs::Platforms::IOS, @project)
    assert_not_nil result
    assert_equal "test_ios_push-production", result.name
  end

  test "app_for_platform returns rpush app for android when full chain exists" do
    # Remove fixture push config so we can create our own
    @android_config.android_push_configuration&.destroy!

    push_config = AndroidPushConfiguration.new(
      android_configuration: @android_config,
      name: "test_android_push",
      firebase_project_id: "my-firebase-project"
    )
    push_config.certificate.attach(
      io: StringIO.new(VALID_SERVICE_ACCOUNT_JSON),
      filename: "service_account.json",
      content_type: "application/json"
    )
    RpushService.stub(:update_android_rpush_app, nil) do
      push_config.save!
    end

    rpush_app = Rpush::Fcm::App.new
    rpush_app.name = "test_android_push"
    rpush_app.firebase_project_id = "my-firebase-project"
    rpush_app.json_key = "fake-service-account-json"
    rpush_app.connections = 30
    rpush_app.save!

    result = RpushService.app_for_platform(Grovs::Platforms::ANDROID, @project)
    assert_not_nil result
    assert_equal "test_android_push", result.name
  end

  test "update_android_rpush_app returns early when push config not found" do
    assert_no_difference "Rpush::Fcm::App.count" do
      RpushService.update_android_rpush_app(-1)
    end
  end

  test "update_android_rpush_app returns early when certificate not attached" do
    push_config = AndroidPushConfiguration.new(
      android_configuration: @android_config,
      name: "no_cert_android"
    )
    # Skip validations since we want no certificate attached
    push_config.save!(validate: false)

    assert_no_difference "Rpush::Fcm::App.count" do
      RpushService.update_android_rpush_app(push_config.id)
    end
  end

  test "update_android_rpush_app creates fcm app when certificate attached" do
    push_config = AndroidPushConfiguration.new(
      android_configuration: @android_config,
      name: "android_fcm_test",
      firebase_project_id: "my-project"
    )
    push_config.certificate.attach(
      io: StringIO.new('{"type":"service_account"}'),
      filename: "service_account.json",
      content_type: "application/json"
    )
    RpushService.stub(:update_android_rpush_app, nil) do
      push_config.save!
    end

    assert_difference "Rpush::Fcm::App.count", 1 do
      RpushService.update_android_rpush_app(push_config.id)
    end

    fcm_app = Rpush::Fcm::App.find_by(name: "android_fcm_test")
    assert_not_nil fcm_app
    assert_equal "my-project", fcm_app.firebase_project_id
  end

  test "update_android_rpush_app replaces existing app with same name" do
    push_config = AndroidPushConfiguration.new(
      android_configuration: @android_config,
      name: "android_replace_test",
      firebase_project_id: "project-v1"
    )
    push_config.certificate.attach(
      io: StringIO.new('{"type":"service_account","version":"v1"}'),
      filename: "service_account.json",
      content_type: "application/json"
    )
    RpushService.stub(:update_android_rpush_app, nil) do
      push_config.save!
    end

    # Create initial app
    RpushService.update_android_rpush_app(push_config.id)
    old_app_id = Rpush::Fcm::App.find_by(name: "android_replace_test").id

    # Update certificate and re-run
    push_config.certificate.attach(
      io: StringIO.new('{"type":"service_account","version":"v2"}'),
      filename: "service_account_v2.json",
      content_type: "application/json"
    )

    assert_no_difference "Rpush::Fcm::App.count" do
      RpushService.update_android_rpush_app(push_config.id)
    end

    new_app = Rpush::Fcm::App.find_by(name: "android_replace_test")
    assert_not_equal old_app_id, new_app.id, "Old app should be destroyed and replaced"
  end


  test "update_ios_rpush_app returns early when push config not found" do
    assert_no_difference "Rpush::Apnsp8::App.count" do
      RpushService.update_ios_rpush_app(-1)
    end
  end

  test "update_ios_rpush_app returns early when certificate not attached" do
    push_config = IosPushConfiguration.new(
      ios_configuration: @ios_config,
      name: "no_cert_ios"
    )
    push_config.save!(validate: false)

    assert_no_difference "Rpush::Apnsp8::App.count" do
      RpushService.update_ios_rpush_app(push_config.id)
    end
  end

  test "update_ios_rpush_app creates development and production apns apps" do
    push_config = IosPushConfiguration.new(
      ios_configuration: @ios_config,
      name: "ios_apns_test",
      certificate_password: "key_id_123"
    )
    push_config.certificate.attach(
      io: StringIO.new(VALID_P8_KEY),
      filename: "AuthKey.p8",
      content_type: "application/octet-stream"
    )
    RpushService.stub(:update_ios_rpush_app, nil) do
      push_config.save!
    end

    assert_difference "Rpush::Apnsp8::App.count", 2 do
      RpushService.update_ios_rpush_app(push_config.id)
    end

    dev_app = Rpush::Apnsp8::App.find_by(name: "ios_apns_test-development")
    prod_app = Rpush::Apnsp8::App.find_by(name: "ios_apns_test-production")

    assert_not_nil dev_app
    assert_not_nil prod_app
    assert_equal "development", dev_app.environment
    assert_equal "production", prod_app.environment
    assert_equal "key_id_123", dev_app.apn_key_id
    assert_equal "ABC123", dev_app.team_id
    assert_equal "com.test.iosapp", dev_app.bundle_id
  end

  test "update_ios_rpush_app replaces existing development and production apps" do
    push_config = IosPushConfiguration.new(
      ios_configuration: @ios_config,
      name: "ios_replace_test",
      certificate_password: "key_v1"
    )
    push_config.certificate.attach(
      io: StringIO.new(VALID_P8_KEY),
      filename: "AuthKey.p8",
      content_type: "application/octet-stream"
    )
    RpushService.stub(:update_ios_rpush_app, nil) do
      push_config.save!
    end

    # Create initial apps
    RpushService.update_ios_rpush_app(push_config.id)
    old_dev_id = Rpush::Apnsp8::App.find_by(name: "ios_replace_test-development").id
    old_prod_id = Rpush::Apnsp8::App.find_by(name: "ios_replace_test-production").id

    # Update certificate and re-run
    push_config.certificate.attach(
      io: StringIO.new(VALID_P8_KEY),
      filename: "AuthKey_v2.p8",
      content_type: "application/octet-stream"
    )

    assert_no_difference "Rpush::Apnsp8::App.count" do
      RpushService.update_ios_rpush_app(push_config.id)
    end

    new_dev = Rpush::Apnsp8::App.find_by(name: "ios_replace_test-development")
    new_prod = Rpush::Apnsp8::App.find_by(name: "ios_replace_test-production")
    assert_not_equal old_dev_id, new_dev.id, "Dev app should be destroyed and replaced"
    assert_not_equal old_prod_id, new_prod.id, "Prod app should be destroyed and replaced"
  end

  test "APNs apps get their connection count from RPUSH_APNS_CONNECTIONS, default 2" do
    @ios_config.ios_push_configuration&.destroy!
    push_config = IosPushConfiguration.new(ios_configuration: @ios_config, name: "conn_push", certificate_password: "key123")
    push_config.certificate.attach(io: StringIO.new(VALID_P8_KEY), filename: "AuthKey.p8", content_type: "application/octet-stream")
    RpushService.stub(:update_ios_rpush_app, nil) { push_config.save! }
    app = RpushService.create_apple_apns2_app(push_config, "conn-test", "development")
    assert_equal 2, app.connections
    ENV["RPUSH_APNS_CONNECTIONS"] = "3"
    app = RpushService.create_apple_apns2_app(push_config, "conn-test-3", "development")
    assert_equal 3, app.connections
  ensure
    ENV.delete("RPUSH_APNS_CONNECTIONS")
  end

  test "FCM apps get their connection count from RPUSH_FCM_CONNECTIONS, default 30" do
    push_config = android_push_configurations(:one)
    push_config.certificate.attach(io: StringIO.new({ type: "service_account" }.to_json), filename: "sa.json")
    assert_equal 30, RpushService.create_android_app(push_config, "fcm-conn-default").connections
    ENV["RPUSH_FCM_CONNECTIONS"] = "60"
    assert_equal 60, RpushService.create_android_app(push_config, "fcm-conn-60").connections
  ensure
    ENV.delete("RPUSH_FCM_CONNECTIONS")
  end

  test "removing an app drops its unsent pushes and leaves sent history to the purge job" do
    old = Rpush::Fcm::App.create!(name: "fcm-rotate", firebase_project_id: "p", json_key: "{}", connections: 1)
    sent = Rpush::Fcm::Notification.create!(app: old, device_token: "t1", notification: { title: "x" }, delivered: true)
    unsent = Rpush::Fcm::Notification.create!(app: old, device_token: "t2", notification: { title: "x" })

    RpushService.remove_app(old)

    assert_nil Rpush::Client::ActiveRecord::App.find_by(id: old.id)
    assert Rpush::Client::ActiveRecord::Notification.exists?(sent.id)
    assert_nil Rpush::Client::ActiveRecord::Notification.find_by(id: unsent.id)
  ensure
    Rpush::Fcm::Notification.where(app_id: old&.id).delete_all
  end
end
