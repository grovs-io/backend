require "test_helper"

class AndroidServerApiKeyTest < ActiveSupport::TestCase
  fixtures :instances

  VALID_SERVICE_ACCOUNT_JSON = {
    type: "service_account",
    project_id: "test-project",
    private_key_id: "key123",
    client_email: "test@test-project.iam.gserviceaccount.com"
  }.to_json.freeze

  # === certificate_must_be_attached ===

  test "invalid without file attached" do
    app = Application.create!(platform: Grovs::Platforms::ANDROID, instance: instances(:one))
    config = AndroidConfiguration.create!(identifier: "com.test.apikey", application: app)

    api_key = AndroidServerApiKey.new(android_configuration: config)
    assert_not api_key.valid?
    assert_includes api_key.errors[:file], "must be attached"
  end

  test "valid with valid JSON file attached" do
    app = Application.create!(platform: Grovs::Platforms::ANDROID, instance: instances(:one))
    config = AndroidConfiguration.create!(identifier: "com.test.apikey2", application: app)

    api_key = AndroidServerApiKey.new(android_configuration: config)
    api_key.file.attach(
      io: StringIO.new(VALID_SERVICE_ACCOUNT_JSON),
      filename: "service_account.json",
      content_type: "application/json"
    )

    assert api_key.valid?
  end

  # === file extension validation ===

  test "invalid with non-JSON file extension" do
    app = Application.create!(platform: Grovs::Platforms::ANDROID, instance: instances(:one))
    config = AndroidConfiguration.create!(identifier: "com.test.apikey.ext", application: app)

    api_key = AndroidServerApiKey.new(android_configuration: config)
    api_key.file.attach(
      io: StringIO.new("not json"),
      filename: "service_account.txt",
      content_type: "text/plain"
    )

    assert_not api_key.valid?
    assert_includes api_key.errors[:file], "must be a JSON file (.json)"
  end

  # === serialization ===

  test "serializer excludes updated_at, created_at, android_configuration_id, and id" do
    app = Application.create!(platform: Grovs::Platforms::ANDROID, instance: instances(:one))
    config = AndroidConfiguration.create!(identifier: "com.test.apikey3", application: app)

    api_key = AndroidServerApiKey.new(android_configuration: config)
    api_key.file.attach(
      io: StringIO.new(VALID_SERVICE_ACCOUNT_JSON),
      filename: "service_account.json",
      content_type: "application/json"
    )
    api_key.save!

    json = AndroidServerApiKeySerializer.serialize(api_key)

    assert_not json.key?("updated_at")
    assert_not json.key?("created_at")
    assert_not json.key?("android_configuration_id")
    assert_not json.key?("id")
  end

  test "serializer includes filename when file is attached" do
    app = Application.create!(platform: Grovs::Platforms::ANDROID, instance: instances(:one))
    config = AndroidConfiguration.create!(identifier: "com.test.apikey4", application: app)

    api_key = AndroidServerApiKey.new(android_configuration: config)
    api_key.file.attach(
      io: StringIO.new(VALID_SERVICE_ACCOUNT_JSON),
      filename: "service_account.json",
      content_type: "application/json"
    )
    api_key.save!

    json = AndroidServerApiKeySerializer.serialize(api_key)
    assert_equal "service_account.json", json["file"]
  end

  test "serializer returns nil for file when not attached" do
    app = Application.create!(platform: Grovs::Platforms::ANDROID, instance: instances(:one))
    config = AndroidConfiguration.create!(identifier: "com.test.apikey5", application: app)

    # Build without saving to skip validation
    api_key = AndroidServerApiKey.new(android_configuration: config)
    json = AndroidServerApiKeySerializer.serialize(api_key)
    assert_nil json["file"]
  end
end
