require "test_helper"

class IosServerApiKeySerializerTest < ActiveSupport::TestCase
  fixtures :ios_configurations, :applications, :instances

  # Matches the format of a real Apple .p8 file (PKCS#8 PEM header required by model validator)
  VALID_P8_KEY = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg\n-----END PRIVATE KEY-----".freeze

  setup do
    @key = IosServerApiKey.create!(
      ios_configuration: ios_configurations(:one),
      key_id: "TESTKEY123",
      issuer_id: "ISSUER456",
      private_key: VALID_P8_KEY,
      filename: "AuthKey.p8"
    )
  end

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION -- assert_equal for every declared attribute
  # ---------------------------------------------------------------------------
  test "serializes every declared attribute with correct values" do
    result = IosServerApiKeySerializer.serialize(@key)

    assert_equal "TESTKEY123",                result["key_id"]
    assert_equal "ISSUER456",                 result["issuer_id"]
    assert_equal "AuthKey.p8",                result["filename"]
    assert_not_nil result["created_at"], "Expected created_at to be present"
  end

  test "configured is true when private_key is present" do
    result = IosServerApiKeySerializer.serialize(@key)

    assert_equal true, result["configured"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION -- internal/sensitive fields must NOT appear
  # ---------------------------------------------------------------------------
  test "excludes private_key ios_configuration_id updated_at and id" do
    result = IosServerApiKeySerializer.serialize(@key)

    %w[private_key ios_configuration_id updated_at id].each do |field|
      assert_not_includes result.keys, field
    end
  end

  test "private_key never appears in serialized output even as a substring" do
    result = IosServerApiKeySerializer.serialize(@key)
    json_string = result.to_json

    assert_not_includes json_string, "BEGIN PRIVATE KEY",
      "Private key content must never leak into serialized output"
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING -- returns nil for nil input
  # ---------------------------------------------------------------------------
  test "returns nil for nil input" do
    assert_nil IosServerApiKeySerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING -- verify size AND distinct values
  # ---------------------------------------------------------------------------
  test "serializes a collection with correct size and distinct key_ids" do
    key_b = IosServerApiKey.create!(
      ios_configuration: ios_configurations(:one),
      key_id: "OTHERKEY999",
      issuer_id: "ISSUER789",
      private_key: VALID_P8_KEY,
      filename: "AuthKey2.p8"
    )
    results = IosServerApiKeySerializer.serialize([@key, key_b])

    assert_equal 2, results.size

    key_ids = results.map { |r| r["key_id"] }
    assert_includes key_ids, "TESTKEY123"
    assert_includes key_ids, "OTHERKEY999"
    assert_equal key_ids.uniq.size, key_ids.size
  end

  test "empty collection returns empty array" do
    assert_equal [], IosServerApiKeySerializer.serialize([])
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES -- configured reflects private_key presence
  # ---------------------------------------------------------------------------
  test "output contains only declared attributes plus configured" do
    result = IosServerApiKeySerializer.serialize(@key)

    assert_equal %w[configured created_at filename issuer_id key_id], result.keys.sort
  end

  test "configured is false when private_key is blank" do
    blank_key = IosServerApiKey.new(
      ios_configuration: ios_configurations(:one),
      key_id: "BLANKKEY",
      issuer_id: "BLANKISSUER",
      private_key: nil,
      filename: "BlankKey.p8"
    )
    result = IosServerApiKeySerializer.serialize(blank_key)

    assert_equal false, result["configured"]
  end
end
