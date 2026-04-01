require "test_helper"

class AndroidServerApiKeySerializerTest < ActiveSupport::TestCase
  fixtures :android_server_api_keys, :android_configurations, :applications, :instances

  test "file is nil when no file attached" do
    key = android_server_api_keys(:one)
    result = AndroidServerApiKeySerializer.serialize(key)

    assert_includes result.keys, "file"
    assert_nil result["file"]
  end

  test "file returns filename when file is attached" do
    key = android_server_api_keys(:one)
    key.file.attach(
      io: StringIO.new("fake-service-account-content"),
      filename: "service_account.json",
      content_type: "application/json"
    )

    result = AndroidServerApiKeySerializer.serialize(key)

    assert_equal "service_account.json", result["file"]
  end

  test "excludes internal fields" do
    key = android_server_api_keys(:one)
    result = AndroidServerApiKeySerializer.serialize(key)

    %w[updated_at created_at android_configuration_id id].each do |field|
      assert_not_includes result.keys, field, "expected #{field} to be excluded"
    end
  end

  test "returns nil for nil input" do
    assert_nil AndroidServerApiKeySerializer.serialize(nil)
  end

  test "serializes a collection" do
    key = android_server_api_keys(:one)
    result = AndroidServerApiKeySerializer.serialize([key, key])

    assert_equal 2, result.size
    assert_includes result[0].keys, "file"
    assert_includes result[1].keys, "file"
  end
end
