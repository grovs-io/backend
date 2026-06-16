require "test_helper"

class CustomHostnameAvailabilityTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :custom_hostnames

  test "available for a fresh subdomain" do
    assert DomainConfigurationService.custom_hostname_available?("links.fresh-co.com")
  end

  test "normalizes before checking (uppercase, trailing dot, surrounding spaces)" do
    assert DomainConfigurationService.custom_hostname_available?("  LINKS.Fresh-Co.com.  ")
  end

  test "rejects an apex domain" do
    assert_not DomainConfigurationService.custom_hostname_available?("fresh-co.com")
  end

  test "rejects a multi-part-TLD apex but allows its subdomain" do
    assert_not DomainConfigurationService.custom_hostname_available?("acme.co.uk")
    assert DomainConfigurationService.custom_hostname_available?("links.acme.co.uk")
  end

  test "rejects a subdomain of one of our MAIN domains" do
    assert_not DomainConfigurationService.custom_hostname_available?("links.sqd.link")
  end

  test "rejects a hostname already taken by a CustomHostname" do
    assert_not DomainConfigurationService.custom_hostname_available?(custom_hostnames(:acme_active).hostname)
  end

  test "rejects a hostname colliding with an existing (enterprise) Domain row" do
    domains(:two).update!(domain: "enterprise-co.com", subdomain: "go")
    assert_not DomainConfigurationService.custom_hostname_available?("go.enterprise-co.com")
  end

  test "rejects garbage and blank hostnames" do
    assert_not DomainConfigurationService.custom_hostname_available?("not a hostname")
    assert_not DomainConfigurationService.custom_hostname_available?("")
    assert_not DomainConfigurationService.custom_hostname_available?(nil)
  end

  test "rejects a raw Unicode (IDN) hostname but allows its punycode form" do
    assert_not DomainConfigurationService.custom_hostname_available?("münchen.example.com")
    assert DomainConfigurationService.custom_hostname_available?("xn--mnchen-3ya.example.com")
  end
end
