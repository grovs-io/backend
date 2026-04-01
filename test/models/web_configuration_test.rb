require "test_helper"

class WebConfigurationTest < ActiveSupport::TestCase
  fixtures :web_configurations, :applications, :web_configuration_linked_domains, :instances

  # === application_id uniqueness validation ===

  test "valid with unique application_id" do
    config = web_configurations(:one)
    assert config.valid?
  end

  test "invalid with duplicate application_id" do
    existing = web_configurations(:one)
    duplicate = WebConfiguration.new(application: existing.application)
    assert_not duplicate.valid?
    assert duplicate.errors[:application_id].any?
  end

  # === cascade delete ===

  test "destroying web configuration destroys associated application" do
    config = web_configurations(:one)
    app = config.application

    assert_difference "Application.count", -1 do
      config.destroy
    end

    assert_not Application.exists?(app.id)
  end

  test "destroying web configuration destroys linked domains" do
    config = web_configurations(:one)
    domain_count = config.web_configuration_linked_domains.count
    assert domain_count > 0

    assert_difference "WebConfigurationLinkedDomain.count", -domain_count do
      config.destroy
    end
  end

  # === serialization ===

  test "serializer excludes internal fields" do
    config = web_configurations(:one)
    json = WebConfigurationSerializer.serialize(config)

    assert_nil json["id"]
    assert_nil json["created_at"]
    assert_nil json["updated_at"]
    assert_nil json["application_id"]
  end

  test "serializer includes domains array from linked domains" do
    config = web_configurations(:one)
    json = WebConfigurationSerializer.serialize(config)

    assert json.key?("domains")
    assert_includes json["domains"], "app.example.com"
    assert_includes json["domains"], "www.example.com"
  end

  test "serializer returns empty domains when no linked domains exist" do
    app = Application.create!(instance: instances(:two), platform: Grovs::Platforms::WEB)
    config = WebConfiguration.create!(application: app)
    json = WebConfigurationSerializer.serialize(config)

    assert_equal [], json["domains"]
  end

  # === clear_configuration_cache delegation ===

  test "clear_configuration_cache is delegated to application" do
    config = web_configurations(:one)
    # Calling it should not raise an error — it delegates to application.clear_configuration_cache
    assert_nothing_raised do
      config.clear_configuration_cache
    end
  end
end
