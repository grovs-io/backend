require "test_helper"

class DomainConfigurationServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  setup do
    @project = projects(:one)
    @domain = Domain.create!(project: @project, domain: "test.link", subdomain: "dom#{SecureRandom.hex(2)}")
  end

  # === update_domain ===

  test "update_domain updates attrs" do
    updated = DomainConfigurationService.update_domain(
      domain: @domain,
      attrs: { generic_title: "New Title" }
    )

    assert_equal "New Title", updated.generic_title
  end

  test "update_domain lowercases subdomain" do
    new_sub = "Upper#{SecureRandom.hex(2)}"
    updated = DomainConfigurationService.update_domain(
      domain: @domain,
      attrs: { subdomain: new_sub }
    )

    assert_equal new_sub.downcase, updated.subdomain
  end

  test "update_domain with same subdomain does not raise" do
    updated = DomainConfigurationService.update_domain(
      domain: @domain,
      attrs: { subdomain: @domain.subdomain, generic_title: "Updated Title" }
    )

    assert_equal "Updated Title", updated.generic_title
    assert_equal @domain.subdomain, updated.subdomain
  end

  test "update_domain raises for unavailable subdomain" do
    # Create another domain with target subdomain
    other_project = projects(:one) # same test flag
    Domain.create!(project: other_project, domain: "other.link", subdomain: "taken")

    assert_raises(ArgumentError) do
      DomainConfigurationService.update_domain(
        domain: @domain,
        attrs: { subdomain: "taken" }
      )
    end
  end

  test "update_domain updates google_tracking_id" do
    updated = DomainConfigurationService.update_domain(
      domain: @domain,
      attrs: { google_tracking_id: "G-TESTID123" }
    )

    assert_equal "G-TESTID123", updated.google_tracking_id
    assert_equal "G-TESTID123", @domain.reload.google_tracking_id
  end

  test "update_domain with image_url clears generic_image" do
    updated = DomainConfigurationService.update_domain(
      domain: @domain,
      attrs: { generic_image_url: "https://example.com/image.png" }
    )

    assert_equal "https://example.com/image.png", updated.generic_image_url
  end

  # === subdomain_available? ===

  test "subdomain_available returns true for available subdomain" do
    result = DomainConfigurationService.subdomain_available?(
      subdomain: "avail#{SecureRandom.hex(4)}",
      is_test: false
    )
    assert result
  end

  test "subdomain_available returns false for taken subdomain" do
    result = DomainConfigurationService.subdomain_available?(
      subdomain: @domain.subdomain,
      is_test: @project.test?
    )
    assert_not result
  end

  test "subdomain_available returns false for forbidden subdomain" do
    result = DomainConfigurationService.subdomain_available?(
      subdomain: Grovs::Subdomains::FORBIDDEN.first,
      is_test: false
    )
    assert_not result
  end

  test "subdomain_available returns false for invalid format" do
    result = DomainConfigurationService.subdomain_available?(
      subdomain: "---",
      is_test: false
    )
    assert_not result
  end

  # === domain_available? ===

  test "domain_available returns true for unknown domain" do
    result = DomainConfigurationService.domain_available?(domain_name: "unknown-#{SecureRandom.hex(8)}.com")
    assert result
  end

  test "domain_available returns false for existing domain" do
    result = DomainConfigurationService.domain_available?(domain_name: @domain.domain)
    assert_not result
  end
end
