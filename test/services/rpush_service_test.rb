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

  # === app_for_platform ===

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

  # === send_push_for_notification_and_visitor ===

  test "send_push does nothing when device has no platform" do
    notification = Notification.create!(title: "Test", subtitle: "Sub", project: @project)
    visitor = visitors(:ios_visitor)
    device = visitor.device
    device.update_columns(platform: nil)

    assert_nothing_raised do
      RpushService.send_push_for_notification_and_visitor(notification, visitor)
    end
  end

  test "send_push does nothing when device has no push_token" do
    notification = Notification.create!(title: "Test", subtitle: "Sub", project: @project)
    visitor = visitors(:ios_visitor)
    # ios_device fixture has no push_token by default
    assert_nil visitor.device.push_token

    assert_nothing_raised do
      RpushService.send_push_for_notification_and_visitor(notification, visitor)
    end
  end

  test "send_push routes to ios and creates Rpush::Apnsp8::Notification with correct payload" do
    notification = Notification.create!(title: "Hello", subtitle: "World", project: @project)
    visitor = visitors(:ios_visitor)
    device = visitor.device
    device.update_columns(push_token: "ios_token_abc123")

    fake_rpush_app = Rpush::Apnsp8::App.new
    fake_rpush_app.name = "ios-push-test"
    fake_rpush_app.apn_key = "fake-key"
    fake_rpush_app.environment = "production"
    fake_rpush_app.apn_key_id = "key123"
    fake_rpush_app.team_id = "ABC123"
    fake_rpush_app.bundle_id = "com.test.iosapp"
    fake_rpush_app.connections = 1
    fake_rpush_app.save!

    RpushService.stub(:app_for_platform, fake_rpush_app) do
      assert_difference "Rpush::Apnsp8::Notification.count", 1 do
        RpushService.send_push_for_notification_and_visitor(notification, visitor)
      end

      rpush_notification = Rpush::Apnsp8::Notification.last
      assert_equal "ios_token_abc123", rpush_notification.device_token
      assert_equal fake_rpush_app.id, rpush_notification.app_id

      # Verify the alert payload contains the notification title and subtitle
      assert_equal({ "title" => "Hello", "subtitle" => "World" }, rpush_notification.alert)
    end
  end

  test "send_push routes to android and creates Rpush::Fcm::Notification with correct payload" do
    notification = Notification.create!(title: "Hello", subtitle: "World", project: @project)
    visitor = visitors(:android_visitor)
    device = visitor.device
    device.update_columns(push_token: "android_token_xyz789")

    fake_rpush_app = Rpush::Fcm::App.new
    fake_rpush_app.name = "android-push-test"
    fake_rpush_app.firebase_project_id = "my-firebase-project"
    fake_rpush_app.json_key = "fake-service-account-json"
    fake_rpush_app.connections = 30
    fake_rpush_app.save!

    RpushService.stub(:app_for_platform, fake_rpush_app) do
      assert_difference "Rpush::Fcm::Notification.count", 1 do
        RpushService.send_push_for_notification_and_visitor(notification, visitor)
      end

      rpush_notification = Rpush::Fcm::Notification.last
      assert_equal "android_token_xyz789", rpush_notification.device_token
      assert_equal fake_rpush_app.id, rpush_notification.app_id

      # Verify the FCM notification payload (stored with string keys after save)
      assert_equal "Hello", rpush_notification.notification["title"]
      assert_equal "World", rpush_notification.notification["body"]
      # Verify the data payload includes the linksquared flag
      assert_equal "true", rpush_notification.data["linksquared"]
    end
  end

  test "send_push does nothing when no rpush app found for platform" do
    notification = Notification.create!(title: "Hello", subtitle: "World", project: @project)
    visitor = visitors(:ios_visitor)
    device = visitor.device
    device.update_columns(push_token: "some_token")

    RpushService.stub(:app_for_platform, nil) do
      assert_no_difference "Rpush::Apnsp8::Notification.count" do
        assert_nothing_raised do
          RpushService.send_push_for_notification_and_visitor(notification, visitor)
        end
      end
    end
  end

  # === update_android_rpush_app ===

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

  # === update_ios_rpush_app ===

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
end
