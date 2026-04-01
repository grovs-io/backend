require "test_helper"

class AndroidPushConfigurationTest < ActiveSupport::TestCase
  fixtures :android_configurations, :applications, :instances

  VALID_FIREBASE_JSON = {
    type: "service_account",
    project_id: "test-firebase-project",
    private_key_id: "key123",
    client_email: "firebase-adminsdk@test.iam.gserviceaccount.com"
  }.to_json.freeze

  test "invalid without certificate attached" do
    config = AndroidPushConfiguration.new(android_configuration: android_configurations(:one))
    assert_not config.valid?
    assert_includes config.errors[:certificate], "must be attached"
  end

  # === certificate extension validation ===

  test "invalid with non-JSON file extension" do
    config = AndroidPushConfiguration.new(android_configuration: android_configurations(:one))
    config.certificate.attach(
      io: StringIO.new("not json"),
      filename: "cert.txt",
      content_type: "text/plain"
    )

    assert_not config.valid?
    assert_includes config.errors[:certificate], "must be a JSON file (.json)"
  end

  # === existing behavior ===

  test "build_up generates a name with android_config prefix and unique suffix" do
    config = AndroidPushConfiguration.new(android_configuration: android_configurations(:one))
    config.send(:build_up)

    assert config.name.present?
    assert config.name.start_with?("android_config_")
    assert_equal 35, config.name.length # "android_config_" (15) + hex(10) (20)
  end

  test "build_up does not overwrite an existing name" do
    config = AndroidPushConfiguration.new(
      android_configuration: android_configurations(:one),
      name: "my_custom_name"
    )
    config.send(:build_up)

    assert_equal "my_custom_name", config.name
  end

  test "create triggers after_create_commit callback" do
    config = AndroidPushConfiguration.new(android_configuration: android_configurations(:one))
    config.certificate.attach(
      io: StringIO.new(VALID_FIREBASE_JSON),
      filename: "service_account.json",
      content_type: "application/json"
    )

    RpushService.stub(:update_android_rpush_app, nil) do
      assert config.save
      assert config.persisted?
      assert config.name.start_with?("android_config_")
    end
  end

  test "destroy calls cleanup_resources and stubs RpushService" do
    config = AndroidPushConfiguration.new(android_configuration: android_configurations(:one))
    config.certificate.attach(
      io: StringIO.new(VALID_FIREBASE_JSON),
      filename: "service_account.json",
      content_type: "application/json"
    )

    RpushService.stub(:update_android_rpush_app, nil) do
      config.save!
    end

    RpushService.stub(:app_for_platform, nil) do
      assert_nothing_raised do
        config.destroy
      end
    end
  end
end
