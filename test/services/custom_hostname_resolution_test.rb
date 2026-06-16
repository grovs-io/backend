require "test_helper"

class CustomHostnameResolutionTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :custom_hostnames, :links, :redirect_configs

  # after_commit invalidation does not fire under transactional fixtures, so we flush
  # the Redis model cache between tests.
  setup do
    enable_custom_domains!
    REDIS.flushdb
  end
  teardown { disable_custom_domains! }

  test "custom_hostname_for resolves an active alias to its Domain" do
    assert_equal custom_hostnames(:acme_active).domain_id,
                 LinksService.custom_hostname_for("links.acme.com")&.id
  end

  test "custom_hostname_for is case-insensitive" do
    assert_equal custom_hostnames(:acme_active).domain_id,
                 LinksService.custom_hostname_for("LINKS.Acme.com")&.id
  end

  test "custom_hostname_for returns nil for a non-active hostname" do
    custom_hostnames(:acme_active).update!(status: "suspended")
    assert_nil LinksService.custom_hostname_for("links.acme.com")
  end

  test "custom_hostname_for returns nil when the feature is disabled" do
    disable_custom_domains!
    assert_nil LinksService.custom_hostname_for("links.acme.com")
  end

  test "link_for_request resolves a link via the custom host" do
    primary_ch = CustomHostname.create!(
      project: projects(:one), domain: domains(:one),
      hostname: "primary.acme.example",
      status: "active", ssl_status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_PRIMARY
    )
    primary_ch.send(:clear_cache)
    req = ActionDispatch::TestRequest.create
    req.host = "primary.acme.example"
    req.path = "/#{links(:basic_link).path}"
    assert_equal links(:basic_link).id, LinksService.link_for_request(req)&.id
  end

  test "link_for_request still resolves the canonical sqd.link host" do
    req = ActionDispatch::TestRequest.create
    req.host = "example.sqd.link"
    req.path = "/#{links(:basic_link).path}"
    assert_equal links(:basic_link).id, LinksService.link_for_request(req)&.id
  end

  test "link_for_url rejects a link belonging to another project (cross-tenant guard)" do
    url = "https://example.sqd.link/#{links(:basic_link).path}"
    assert_equal links(:basic_link).id, LinksService.link_for_url(url, projects(:one))&.id
    assert_nil LinksService.link_for_url(url, projects(:two))
  end
end
