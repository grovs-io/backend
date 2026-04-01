require "test_helper"

class IosConfigurationTest < ActiveSupport::TestCase
  fixtures :instances

  # === validations ===

  test "validates application_id uniqueness" do
    app = Application.create!(platform: Grovs::Platforms::IOS, instance: instances(:one))
    IosConfiguration.create!(app_prefix: "ABC123", application: app)

    duplicate = IosConfiguration.new(app_prefix: "DEF456", application: app)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:application_id], "has already been taken"
  end

  # === delete_application ===

  test "destroying ios configuration also destroys the parent application" do
    app = Application.create!(platform: Grovs::Platforms::IOS, instance: instances(:one))
    config = IosConfiguration.create!(app_prefix: "ABC123", application: app)

    assert_difference "Application.count", -1 do
      config.destroy
    end

    assert_not Application.exists?(app.id)
  end

  # === dependent destroy ===

  test "destroying ios configuration destroys associated ios_server_api_key" do
    app = Application.create!(platform: Grovs::Platforms::IOS, instance: instances(:one))
    config = IosConfiguration.create!(app_prefix: "ABC123", application: app)
    IosServerApiKey.create!(
      ios_configuration: config,
      private_key: "-----BEGIN PRIVATE KEY-----\nfake\n-----END PRIVATE KEY-----",
      key_id: "KEY123",
      issuer_id: "ISSUER456",
      filename: "key.p8"
    )

    assert_difference "IosServerApiKey.count", -1 do
      config.destroy
    end
  end

  # === serialization ===

  test "serializer excludes updated_at, created_at, id, and application_id" do
    app = Application.create!(platform: Grovs::Platforms::IOS, instance: instances(:one))
    config = IosConfiguration.create!(app_prefix: "ABC123", application: app)
    json = IosConfigurationSerializer.serialize(config)

    assert_not json.key?("updated_at")
    assert_not json.key?("created_at")
    assert_not json.key?("id")
    assert_not json.key?("application_id")
  end

  test "serializer includes push_configuration and server_api_key keys" do
    app = Application.create!(platform: Grovs::Platforms::IOS, instance: instances(:one))
    config = IosConfiguration.create!(app_prefix: "ABC123", application: app)
    json = IosConfigurationSerializer.serialize(config)

    assert json.key?("push_configuration")
    assert json.key?("server_api_key")
  end
end
