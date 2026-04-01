require "test_helper"

class WebConfigurationLinkedDomainTest < ActiveSupport::TestCase
  fixtures :web_configuration_linked_domains, :web_configurations, :applications, :instances

  # === associations ===

  test "belongs to web configuration" do
    linked = web_configuration_linked_domains(:primary_domain)
    assert_equal web_configurations(:one), linked.web_configuration
  end

  # === fixture data ===

  test "primary domain fixture loads correctly" do
    linked = web_configuration_linked_domains(:primary_domain)
    assert_equal "app.example.com", linked.domain
  end

  test "secondary domain fixture loads correctly" do
    linked = web_configuration_linked_domains(:secondary_domain)
    assert_equal "www.example.com", linked.domain
  end

  # === creation ===

  test "can be created with valid attributes" do
    linked = WebConfigurationLinkedDomain.new(
      web_configuration: web_configurations(:one),
      domain: "new.example.com"
    )
    assert linked.save
    assert_equal "new.example.com", linked.reload.domain
  end

  test "multiple linked domains can belong to same web configuration" do
    config = web_configurations(:one)
    initial_count = config.web_configuration_linked_domains.count

    WebConfigurationLinkedDomain.create!(web_configuration: config, domain: "extra.example.com")
    assert_equal initial_count + 1, config.web_configuration_linked_domains.reload.count
  end
end
