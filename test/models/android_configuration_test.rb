require "test_helper"

class AndroidConfigurationTest < ActiveSupport::TestCase
  fixtures :instances

  # === validations ===

  test "validates application_id uniqueness" do
    app = Application.create!(platform: Grovs::Platforms::ANDROID, instance: instances(:one))
    AndroidConfiguration.create!(identifier: "com.test.app", application: app)

    duplicate = AndroidConfiguration.new(identifier: "com.other.app", application: app)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:application_id], "has already been taken"
  end

  # === delete_application ===

  test "destroying android configuration also destroys the parent application" do
    app = Application.create!(platform: Grovs::Platforms::ANDROID, instance: instances(:one))
    config = AndroidConfiguration.create!(identifier: "com.test.cascade", application: app)

    assert_difference "Application.count", -1 do
      config.destroy
    end

    assert_not Application.exists?(app.id)
  end

  # === serialization ===

  test "serializer excludes updated_at, created_at, id, and application_id" do
    app = Application.create!(platform: Grovs::Platforms::ANDROID, instance: instances(:one))
    config = AndroidConfiguration.create!(identifier: "com.test.json", application: app)
    json = AndroidConfigurationSerializer.serialize(config)

    assert_not json.key?("updated_at")
    assert_not json.key?("created_at")
    assert_not json.key?("id")
    assert_not json.key?("application_id")
  end

  test "serializer includes identifier and push_configuration key" do
    app = Application.create!(platform: Grovs::Platforms::ANDROID, instance: instances(:one))
    config = AndroidConfiguration.create!(identifier: "com.test.json2", application: app)
    json = AndroidConfigurationSerializer.serialize(config)

    assert_equal "com.test.json2", json["identifier"]
    assert json.key?("push_configuration")
    assert json.key?("server_api_key")
  end
end
