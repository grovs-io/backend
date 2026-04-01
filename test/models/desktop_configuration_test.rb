require "test_helper"

class DesktopConfigurationTest < ActiveSupport::TestCase
  fixtures :instances

  # === validations ===

  test "validates application_id uniqueness" do
    app = Application.create!(platform: Grovs::Platforms::DESKTOP, instance: instances(:one))
    DesktopConfiguration.create!(application: app)

    duplicate = DesktopConfiguration.new(application: app)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:application_id], "has already been taken"
  end

  # === delete_application ===

  test "destroying desktop configuration also destroys the parent application" do
    app = Application.create!(platform: Grovs::Platforms::DESKTOP, instance: instances(:one))
    config = DesktopConfiguration.create!(application: app)

    assert_difference "Application.count", -1 do
      config.destroy
    end

    assert_not Application.exists?(app.id)
  end

  # === serialization ===

  test "serializer excludes updated_at, created_at, id, and application_id" do
    app = Application.create!(platform: Grovs::Platforms::DESKTOP, instance: instances(:one))
    config = DesktopConfiguration.create!(application: app)
    json = DesktopConfigurationSerializer.serialize(config)

    assert_not json.key?("updated_at")
    assert_not json.key?("created_at")
    assert_not json.key?("id")
    assert_not json.key?("application_id")
  end

  test "serializer includes configuration attributes" do
    app = Application.create!(platform: Grovs::Platforms::DESKTOP, instance: instances(:one))
    config = DesktopConfiguration.create!(
      application: app,
      fallback_url: "https://example.com",
      mac_enabled: true,
      windows_enabled: false
    )
    json = DesktopConfigurationSerializer.serialize(config)

    assert_equal "https://example.com", json["fallback_url"]
    assert_equal true, json["mac_enabled"]
    assert_equal false, json["windows_enabled"]
  end
end
