require "test_helper"

class WebConfigurationSerializerTest < ActiveSupport::TestCase
  fixtures :web_configurations, :applications, :instances, :web_configuration_linked_domains

  test "serializes domains from linked domains" do
    wc = web_configurations(:one)
    result = WebConfigurationSerializer.serialize(wc)

    assert_kind_of Array, result["domains"]
    assert_equal ["app.example.com", "www.example.com"].sort, result["domains"].sort
  end

  test "domains contain fixture values" do
    wc = web_configurations(:one)
    result = WebConfigurationSerializer.serialize(wc)

    # Fixtures: primary_domain ("app.example.com") and secondary_domain ("www.example.com")
    assert_includes result["domains"], "app.example.com"
    assert_includes result["domains"], "www.example.com"
    assert_equal 2, result["domains"].size
  end

  test "domains is empty when no linked domains exist" do
    wc = web_configurations(:one)
    # Remove all linked domains
    wc.web_configuration_linked_domains.destroy_all

    result = WebConfigurationSerializer.serialize(wc)

    assert_equal [], result["domains"]
  end

  test "excludes internal fields" do
    wc = web_configurations(:one)
    result = WebConfigurationSerializer.serialize(wc)

    %w[updated_at created_at id application_id].each do |field|
      assert_not_includes result.keys, field, "expected #{field} to be excluded"
    end
  end

  test "returns nil for nil input" do
    assert_nil WebConfigurationSerializer.serialize(nil)
  end

  test "serializes a collection" do
    wc = web_configurations(:one)
    result = WebConfigurationSerializer.serialize([wc, wc])

    assert_equal 2, result.size
    assert_kind_of Array, result[0]["domains"]
    assert_kind_of Array, result[1]["domains"]
  end
end
