require "test_helper"

class IosPushConfigurationTest < ActiveSupport::TestCase
  fixtures :ios_configurations, :applications, :instances

  VALID_P8_KEY = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg\n-----END PRIVATE KEY-----".freeze

  test "invalid without certificate attached" do
    config = IosPushConfiguration.new(ios_configuration: ios_configurations(:one))
    assert_not config.valid?
    assert_includes config.errors[:certificate], "must be attached"
  end

  # === certificate extension validation ===

  test "invalid with non-p8 file extension" do
    config = IosPushConfiguration.new(ios_configuration: ios_configurations(:one))
    config.certificate.attach(
      io: StringIO.new(VALID_P8_KEY),
      filename: "cert.pem",
      content_type: "application/octet-stream"
    )

    assert_not config.valid?
    assert_includes config.errors[:certificate], "must be a .p8 file"
  end

  # === existing behavior ===

  test "build_up generates a name with ios_config prefix and unique suffix" do
    config = IosPushConfiguration.new(ios_configuration: ios_configurations(:one))
    config.send(:build_up)

    assert config.name.present?
    assert config.name.start_with?("ios_config_")
    assert_equal 31, config.name.length # "ios_config_" (11) + hex(10) (20)
  end

  test "build_up does not overwrite an existing name" do
    config = IosPushConfiguration.new(
      ios_configuration: ios_configurations(:one),
      name: "my_custom_name"
    )
    config.send(:build_up)

    assert_equal "my_custom_name", config.name
  end

  test "create triggers after_create_commit callback" do
    config = IosPushConfiguration.new(ios_configuration: ios_configurations(:one))
    config.certificate.attach(
      io: StringIO.new(VALID_P8_KEY),
      filename: "AuthKey.p8",
      content_type: "application/octet-stream"
    )

    RpushService.stub(:update_ios_rpush_app, nil) do
      assert config.save
      assert config.persisted?
      assert config.name.start_with?("ios_config_")
    end
  end

  test "destroy calls cleanup_resources and stubs RpushService" do
    config = IosPushConfiguration.new(ios_configuration: ios_configurations(:one))
    config.certificate.attach(
      io: StringIO.new(VALID_P8_KEY),
      filename: "AuthKey.p8",
      content_type: "application/octet-stream"
    )

    RpushService.stub(:update_ios_rpush_app, nil) do
      config.save!
    end

    RpushService.stub(:app_for_platform, nil) do
      assert_nothing_raised do
        config.destroy
      end
    end
  end
end
