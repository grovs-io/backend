require "test_helper"

class CustomHostnameAvailabilityTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :custom_hostnames

  def with_main_domains(hosts)
    original = Grovs::Domains::MAIN
    Grovs::Domains.send(:remove_const, :MAIN)
    Grovs::Domains.const_set(:MAIN, hosts.freeze)
    yield
  ensure
    Grovs::Domains.send(:remove_const, :MAIN)
    Grovs::Domains.const_set(:MAIN, original)
  end

  # deployment_host? short-circuits these, so accepting one provisions a host that serves nothing.
  test "a host under a three-label deployment domain is not available" do
    with_main_domains(%w[links.app.com]) do
      assert_not DomainConfigurationService.custom_hostname_available?("foo.links.app.com")
    end
  end

  test "a host outside the deployment domain is still available" do
    with_main_domains(%w[links.app.com]) do
      assert DomainConfigurationService.custom_hostname_available?("go.otherbrand.io")
    end
  end

  # Registering the ingress itself would instruct a self-referential CNAME.
  test "the configured ingress host is not available" do
    ENV["SELF_HOSTED_INGRESS_HOST"] = "alb.otherbrand.io"
    assert_not DomainConfigurationService.custom_hostname_available?("alb.otherbrand.io")
    assert DomainConfigurationService.custom_hostname_available?("go.otherbrand.io")
  ensure
    ENV.delete("SELF_HOSTED_INGRESS_HOST")
  end

  test "the model rejects a host under a three-label deployment domain" do
    with_main_domains(%w[links.app.com]) do
      ch = CustomHostname.new(project: projects(:one), domain: domains(:one),
                              hostname: "foo.links.app.com", status: "pending", source: "enterprise")
      assert_not ch.valid?
      assert_includes ch.errors[:hostname], "is reserved"
    end
  end

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
