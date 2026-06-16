require "test_helper"

class CustomDomainBrandingTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :links, :redirect_configs

  setup { enable_custom_domains! }
  teardown { disable_custom_domains! }

  test "display_host returns full_domain when no active custom host" do
    assert_equal domains(:one).full_domain, domains(:one).display_host
  end

  test "display_host returns the active custom host when set" do
    domains(:one).update!(active_custom_host: "links.acme.com")
    assert_equal "links.acme.com", domains(:one).display_host
  end

  test "display_host ignores the active custom host when the feature is disabled" do
    domains(:one).update!(active_custom_host: "links.acme.com")
    disable_custom_domains!
    assert_equal domains(:one).full_domain, domains(:one).display_host
  end

  test "link access_path is branded with the active custom host" do
    link = links(:basic_link)
    link.domain.update!(active_custom_host: "links.acme.com")
    assert_equal "https://links.acme.com/#{link.path}", link.access_path
  end

  test "link access_path falls back to the sqd.link host without a custom host" do
    link = links(:basic_link)
    assert_equal "https://#{link.domain.full_domain}/#{link.path}", link.access_path
  end

  test "updating a domain clears the cached lookup the resolver uses (branding flips invalidate resolution)" do
    d = domains(:one)
    expected_key = d.send(:multi_condition_cache_key, { domain: d.domain, subdomain: d.subdomain })
    assert_includes d.cache_keys_to_clear, expected_key
  end
end
