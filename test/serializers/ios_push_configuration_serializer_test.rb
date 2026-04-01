require "test_helper"

class IosPushConfigurationSerializerTest < ActiveSupport::TestCase
  fixtures :ios_push_configurations, :ios_configurations, :applications, :instances

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION -- certificate nil when not attached
  # ---------------------------------------------------------------------------
  test "certificate is nil when no certificate is attached" do
    config = ios_push_configurations(:one)
    result = IosPushConfigurationSerializer.serialize(config)

    assert_includes result.keys, "certificate"
    assert_nil result["certificate"]
  end

  test "certificate returns filename when certificate is attached" do
    config = ios_push_configurations(:one)
    config.certificate.attach(
      io: StringIO.new("fake-cert-data"),
      filename: "cert.p12",
      content_type: "application/x-pkcs12"
    )
    result = IosPushConfigurationSerializer.serialize(config)

    assert_equal "cert.p12", result["certificate"]
  end

  test "attached certificate with custom filename is reflected" do
    config = ios_push_configurations(:one)
    config.certificate.attach(
      io: StringIO.new("apns-cert-data"),
      filename: "MyAPNs.p8",
      content_type: "application/octet-stream"
    )
    result = IosPushConfigurationSerializer.serialize(config)

    assert_equal "MyAPNs.p8", result["certificate"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION -- internal/sensitive fields must NOT appear
  # ---------------------------------------------------------------------------
  test "excludes updated_at created_at id ios_configuration_id certificate_password and name" do
    config = ios_push_configurations(:one)
    result = IosPushConfigurationSerializer.serialize(config)

    %w[updated_at created_at id ios_configuration_id certificate_password name].each do |field|
      assert_not_includes result.keys, field
    end
  end

  test "key_id returns the certificate_password value" do
    config = ios_push_configurations(:one)
    config.certificate_password = "ABC123KEYID"
    result = IosPushConfigurationSerializer.serialize(config)

    assert_equal "ABC123KEYID", result["key_id"]
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING -- returns nil for nil input
  # ---------------------------------------------------------------------------
  test "returns nil for nil input" do
    assert_nil IosPushConfigurationSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING -- verify size
  # ---------------------------------------------------------------------------
  test "serializes a collection with correct size" do
    config = ios_push_configurations(:one)
    results = IosPushConfigurationSerializer.serialize([config])

    assert_equal 1, results.size
    assert_kind_of Hash, results.first
    assert_includes results.first.keys, "certificate"
  end

  test "empty collection returns empty array" do
    assert_equal [], IosPushConfigurationSerializer.serialize([])
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES -- only certificate key present in output
  # ---------------------------------------------------------------------------
  test "output contains only certificate and key_id keys" do
    config = ios_push_configurations(:one)
    result = IosPushConfigurationSerializer.serialize(config)

    assert_equal %w[certificate key_id].sort, result.keys.sort
  end
end
