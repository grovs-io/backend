require "test_helper"

class IosServerApiKeyTest < ActiveSupport::TestCase
  fixtures :instances

  VALID_P8_KEY = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg\n-----END PRIVATE KEY-----".freeze

  # === validations ===

  test "valid with all required attributes" do
    app = Application.create!(platform: Grovs::Platforms::IOS, instance: instances(:one))
    config = IosConfiguration.create!(app_prefix: "ABC123", application: app)

    api_key = IosServerApiKey.new(
      ios_configuration: config,
      private_key: VALID_P8_KEY,
      key_id: "KEY123",
      issuer_id: "ISSUER456"
    )

    assert api_key.valid?
  end

  test "invalid without private_key" do
    app = Application.create!(platform: Grovs::Platforms::IOS, instance: instances(:one))
    config = IosConfiguration.create!(app_prefix: "ABC123", application: app)

    api_key = IosServerApiKey.new(
      ios_configuration: config,
      key_id: "KEY123",
      issuer_id: "ISSUER456"
    )

    assert_not api_key.valid?
    assert_includes api_key.errors[:private_key], "can't be blank"
  end

  test "invalid without key_id" do
    app = Application.create!(platform: Grovs::Platforms::IOS, instance: instances(:one))
    config = IosConfiguration.create!(app_prefix: "ABC123", application: app)

    api_key = IosServerApiKey.new(
      ios_configuration: config,
      private_key: VALID_P8_KEY,
      issuer_id: "ISSUER456"
    )

    assert_not api_key.valid?
    assert_includes api_key.errors[:key_id], "can't be blank"
  end

  test "invalid without issuer_id" do
    app = Application.create!(platform: Grovs::Platforms::IOS, instance: instances(:one))
    config = IosConfiguration.create!(app_prefix: "ABC123", application: app)

    api_key = IosServerApiKey.new(
      ios_configuration: config,
      private_key: VALID_P8_KEY,
      key_id: "KEY123"
    )

    assert_not api_key.valid?
    assert_includes api_key.errors[:issuer_id], "can't be blank"
  end

  # === private key format validation ===

  test "invalid with non-PEM private key content" do
    app = Application.create!(platform: Grovs::Platforms::IOS, instance: instances(:one))
    config = IosConfiguration.create!(app_prefix: "ABC123", application: app)

    api_key = IosServerApiKey.new(
      ios_configuration: config,
      private_key: "this is not a valid key",
      key_id: "KEY123",
      issuer_id: "ISSUER456"
    )

    assert_not api_key.valid?
    assert_includes api_key.errors[:private_key], "must be a valid PKCS#8 private key (.p8 file)"
  end

  # === serialization ===

  test "serializer only includes key_id, issuer_id, filename, created_at, and configured flag" do
    app = Application.create!(platform: Grovs::Platforms::IOS, instance: instances(:one))
    config = IosConfiguration.create!(app_prefix: "ABC123", application: app)

    api_key = IosServerApiKey.create!(
      ios_configuration: config,
      private_key: VALID_P8_KEY,
      key_id: "KEY123",
      issuer_id: "ISSUER456",
      filename: "AuthKey.p8"
    )

    json = IosServerApiKeySerializer.serialize(api_key)

    assert_equal "KEY123", json["key_id"]
    assert_equal "ISSUER456", json["issuer_id"]
    assert_equal "AuthKey.p8", json["filename"]
    assert json.key?("created_at")
    assert_equal true, json["configured"]
  end

  test "serializer excludes private_key, id, and updated_at" do
    app = Application.create!(platform: Grovs::Platforms::IOS, instance: instances(:one))
    config = IosConfiguration.create!(app_prefix: "ABC123", application: app)

    api_key = IosServerApiKey.create!(
      ios_configuration: config,
      private_key: VALID_P8_KEY,
      key_id: "KEY123",
      issuer_id: "ISSUER456"
    )

    json = IosServerApiKeySerializer.serialize(api_key)

    assert_not json.key?("private_key")
    assert_not json.key?("id")
    assert_not json.key?("updated_at")
    assert_not json.key?("ios_configuration_id")
  end

  test "serializer configured flag is true when private_key is present" do
    app = Application.create!(platform: Grovs::Platforms::IOS, instance: instances(:one))
    config = IosConfiguration.create!(app_prefix: "ABC123", application: app)

    api_key = IosServerApiKey.create!(
      ios_configuration: config,
      private_key: VALID_P8_KEY,
      key_id: "KEY123",
      issuer_id: "ISSUER456"
    )

    assert_equal true, IosServerApiKeySerializer.serialize(api_key)["configured"]
  end
end
