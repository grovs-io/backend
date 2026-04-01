require "test_helper"

class LinksServiceTest < ActiveSupport::TestCase
  fixtures :projects, :domains, :links, :instances, :redirect_configs, :custom_redirects, :devices, :visitors

  setup do
    @domain = domains(:one)       # domain: "sqd.link", subdomain: "example", project: one
    @link = links(:basic_link)    # path: "test-path", domain: one
    @project = projects(:one)
    @instance = instances(:one)   # uri_scheme: "testapp"
  end

  # === link_for_request ===

  test "link_for_request returns link when domain and path match" do
    request = OpenStruct.new(domain: "sqd.link", subdomain: "example", path: "/test-path")
    result = LinksService.link_for_request(request)
    assert_equal @link, result
  end

  test "link_for_request returns nil when domain not found" do
    request = OpenStruct.new(domain: "unknown.com", subdomain: "nope", path: "/test-path")
    result = LinksService.link_for_request(request)
    assert_nil result
  end

  test "link_for_request returns nil when path not found on valid domain" do
    request = OpenStruct.new(domain: "sqd.link", subdomain: "example", path: "/no-such-path")
    result = LinksService.link_for_request(request)
    assert_nil result
  end

  test "link_for_request returns nil when subdomain wrong" do
    request = OpenStruct.new(domain: "sqd.link", subdomain: "wrong", path: "/test-path")
    result = LinksService.link_for_request(request)
    assert_nil result
  end

  # === link_for_redirect_url ===

  test "link_for_redirect_url resolves full URL to link" do
    result = LinksService.link_for_redirect_url("https://example.sqd.link/test-path")
    assert_equal @link, result
  end

  test "link_for_redirect_url returns nil for nil url" do
    assert_nil LinksService.link_for_redirect_url(nil)
  end

  test "link_for_redirect_url returns nil when domain not found" do
    result = LinksService.link_for_redirect_url("https://unknown.example.com/path")
    assert_nil result
  end

  test "link_for_redirect_url returns nil when path not found" do
    result = LinksService.link_for_redirect_url("https://example.sqd.link/nonexistent")
    assert_nil result
  end

  # === parse_universal_link ===

  test "parse_universal_link decomposes URL into domain, subdomain, path" do
    result = LinksService.parse_universal_link("https://example.sqd.link/test-path")
    assert_equal "sqd.link", result[:domain]
    assert_equal "example", result[:subdomain]
    assert_equal "test-path", result[:path]
  end

  test "parse_universal_link handles URL without subdomain" do
    result = LinksService.parse_universal_link("https://sqd.link/some-path")
    assert_equal "sqd.link", result[:domain]
    assert_nil result[:subdomain]
    assert_equal "some-path", result[:path]
  end

  test "parse_universal_link returns nil for invalid URL" do
    assert_nil LinksService.parse_universal_link("not-a-url")
  end

  test "parse_universal_link returns nil for non-public-suffix host" do
    assert_nil LinksService.parse_universal_link("http://localhost/path")
  end

  # === strip_query_params ===

  test "strip_query_params removes query string but preserves path" do
    result = LinksService.strip_query_params("https://example.sqd.link/test-path?utm_source=email&foo=bar")
    assert_equal "https://example.sqd.link/test-path", result
  end

  test "strip_query_params returns original string for invalid URL" do
    result = LinksService.strip_query_params("not-a-valid-url")
    assert_equal "not-a-valid-url", result
  end

  test "strip_query_params preserves URL without query params" do
    url = "https://example.sqd.link/test-path"
    assert_equal url, LinksService.strip_query_params(url)
  end

  # === parse_uri ===

  test "parse_uri extracts custom scheme URL as domain=scheme path=host" do
    result = LinksService.parse_uri("testapp://some-path")
    assert_equal "testapp", result[:domain]
    assert_equal "some-path", result[:path]
  end

  test "parse_uri returns nil for URL without scheme" do
    assert_nil LinksService.parse_uri("no-scheme-here")
  end

  # === link_for_url ===

  test "link_for_url resolves HTTP URL to link via domain+path lookup" do
    result = LinksService.link_for_url("https://example.sqd.link/test-path", @project)
    assert_equal @link, result
  end

  test "link_for_url resolves HTTP URL with query params" do
    result = LinksService.link_for_url("https://example.sqd.link/test-path?ref=abc", @project)
    assert_equal @link, result
  end

  test "link_for_url resolves custom scheme via instance uri_scheme fallback" do
    # Ensure instance :one has a test project so link_for_path doesn't crash
    test_project = Project.find_or_create_by!(instance: @instance, test: true) do |p|
      p.name = "Test Project"
      p.identifier = "test-project-linksservice"
    end
    Domain.find_or_create_by!(project: test_project) do |d|
      d.domain = "test-sqd.link"
      d.subdomain = "example"
    end

    # parse_universal_link("testapp://test-path") now returns nil (PublicSuffix rescued)
    # Falls through to parse_uri → domain: "testapp", path: "test-path"
    # Domain lookup for "testapp" fails → Instance.redis_find_by(:uri_scheme, "testapp")
    # finds instance :one → link_for_path("test-path") finds basic_link
    result = LinksService.link_for_url("testapp://test-path", @project)
    assert_equal @link, result
  end

  test "link_for_url returns nil for blank string" do
    assert_nil LinksService.link_for_url("", @project)
  end

  test "link_for_url returns nil for nil" do
    assert_nil LinksService.link_for_url(nil, @project)
  end

  test "link_for_url returns nil for non-ASCII URL" do
    assert_nil LinksService.link_for_url("https://example.com/\u00E9", @project)
  end

  test "link_for_url returns nil for URL without scheme" do
    assert_nil LinksService.link_for_url("example.sqd.link/test-path", @project)
  end

  test "link_for_url returns nil when domain exists but path does not" do
    result = LinksService.link_for_url("https://example.sqd.link/nonexistent-path", @project)
    assert_nil result
  end

  # === generate_valid_path ===

  test "generate_valid_path produces 6-character hex string for production project" do
    path = LinksService.generate_valid_path(@domain)
    assert_equal 6, path.length
    assert_match(/\A[0-9a-f]{6}\z/, path)
  end

  test "generate_valid_path appends -test for test project" do
    @project.update_column(:test, true)
    @domain.reload

    path = LinksService.generate_valid_path(@domain)
    assert path.end_with?("-test"), "Expected '#{path}' to end with '-test'"
    hex_part = path.sub("-test", "")
    assert_equal 6, hex_part.length
    assert_match(/\A[0-9a-f]{6}\z/, hex_part)
  end

  test "generate_valid_path retries on collision until unique" do
    # Create a link with a known path that will collide
    collision_path = "aabb11"
    Link.create!(domain: @domain, path: collision_path, redirect_config: redirect_configs(:one),
                 title: "Collision", subtitle: "x", generated_from_platform: "ios", active: true, sdk_generated: false, data: "[]")

    call_count = 0
    original_hex = SecureRandom.method(:hex)

    fake_hex = lambda { |n|
      call_count += 1
      if call_count == 1
        # First call returns the colliding path (only first 6 chars used)
        collision_path
      else
        # Subsequent calls use real randomness
        original_hex.call(n)
      end
    }

    SecureRandom.stub(:hex, fake_hex) do
      path = LinksService.generate_valid_path(@domain)
      assert_not_equal collision_path, path, "Should have retried past the collision"
      assert_match(/\A[0-9a-f]{6}\z/, path)
      assert call_count >= 2, "Should have called SecureRandom.hex at least twice (collision + retry)"
    end
  end

  # === build_preview_url ===

  test "build_preview_url constructs URL with link access_path" do
    ENV["PREVIEW_BASE_URL"] = "https://preview.sqd.link"

    url = LinksService.build_preview_url(@link)
    uri = URI.parse(url)
    params = URI.decode_www_form(uri.query)
    url_param = params.find { |k, _| k == "url" }

    assert_not_nil url_param
    assert_equal @link.access_path, url_param[1]
    assert url.start_with?("https://preview.sqd.link")
  ensure
    ENV.delete("PREVIEW_BASE_URL")
  end

  test "build_preview_url returns nil when PREVIEW_BASE_URL not set" do
    ENV.delete("PREVIEW_BASE_URL")
    assert_nil LinksService.build_preview_url(@link)
  end

  test "build_preview_url returns nil when link is nil" do
    ENV["PREVIEW_BASE_URL"] = "https://preview.sqd.link"
    assert_nil LinksService.build_preview_url(nil)
  ensure
    ENV.delete("PREVIEW_BASE_URL")
  end

  # === build_direct_redirect_for_preview ===

  test "build_direct_redirect_for_preview returns nil when redirect has open_app_if_installed true" do
    redirect = custom_redirects(:ios_redirect_for_basic_link) # open_app_if_installed: true
    result = LinksService.build_direct_redirect_for_preview(@link, redirect)
    assert_nil result
  end

  test "build_direct_redirect_for_preview returns URL with UTM params when open_app_if_installed false" do
    redirect = custom_redirects(:android_redirect_for_basic_link) # open_app_if_installed: false
    result = LinksService.build_direct_redirect_for_preview(@link, redirect)

    assert_not_nil result
    uri = URI.parse(result)
    params = Hash[URI.decode_www_form(uri.query)]

    assert_equal @link.tracking_campaign, params["utm_campaign"]
    assert_equal @link.tracking_source, params["utm_source"]
    assert_equal @link.tracking_medium, params["utm_medium"]
  end

  test "build_direct_redirect_for_preview returns nil when redirect is nil" do
    assert_nil LinksService.build_direct_redirect_for_preview(@link, nil)
  end

  # === build_redirect_url_for_preview ===

  test "build_redirect_url_for_preview returns direct redirect URL for android when open_app_if_installed false" do
    device = devices(:android_device)
    # android_redirect_for_basic_link has open_app_if_installed: false
    url = LinksService.build_redirect_url_for_preview("https://example.sqd.link/test-path", @link, device)

    # Should return the custom redirect URL (not the fallback)
    assert url.start_with?("https://example.com/android-custom")
    uri = URI.parse(url)
    params = Hash[URI.decode_www_form(uri.query)]
    assert_equal @link.tracking_campaign, params["utm_campaign"]
  end

  test "build_redirect_url_for_preview returns fallback URL for ios when open_app_if_installed true" do
    device = devices(:ios_device)
    # ios_redirect_for_basic_link has open_app_if_installed: true, so build_direct_redirect returns nil
    # => falls through to go_to_fallback path
    url = LinksService.build_redirect_url_for_preview("https://example.sqd.link/test-path", @link, device)

    uri = URI.parse(url)
    params = Hash[URI.decode_www_form(uri.query)]
    assert_equal "true", params["go_to_fallback"]
    assert url.start_with?("https://example.sqd.link/test-path")
  end

  test "build_redirect_url_for_preview returns fallback for platform with no custom redirect" do
    device = devices(:web_device)
    url = LinksService.build_redirect_url_for_preview("https://example.sqd.link/test-path", @link, device)

    uri = URI.parse(url)
    params = Hash[URI.decode_www_form(uri.query)]
    assert_equal "true", params["go_to_fallback"]
  end

  test "build_redirect_url_for_preview returns nil when url_param is nil" do
    device = devices(:ios_device)
    assert_nil LinksService.build_redirect_url_for_preview(nil, @link, device)
  end

  test "build_redirect_url_for_preview returns nil when link is nil" do
    device = devices(:ios_device)
    assert_nil LinksService.build_redirect_url_for_preview("https://example.com", nil, device)
  end

  # === link_for_project_and_path ===

  test "link_for_project_and_path returns link for valid project and path" do
    result = LinksService.link_for_project_and_path(@project, "test-path")
    assert_equal @link, result
  end

  test "link_for_project_and_path returns nil for wrong path" do
    result = LinksService.link_for_project_and_path(@project, "nonexistent")
    assert_nil result
  end
end
