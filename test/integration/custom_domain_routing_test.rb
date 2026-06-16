require "test_helper"

# Reserved subdomain labels (sdk/api/go/preview/mcp) on a CUSTOM (non-MAIN) host
# must route to the public link handler, never to the SDK/API/preview machinery.
# On our own MAIN domains those labels stay reserved.
class CustomDomainRoutingTest < ActionDispatch::IntegrationTest
  test "sdk.<custom-domain> routes to the public link handler, not the SDK API" do
    assert_recognizes(
      { controller: "public/links", action: "open_app_link", value: "x" },
      { path: "http://sdk.acme-custom.com/x", method: :get }
    )
  end

  test "api.<custom-domain> routes to the public link handler, not the dashboard API" do
    assert_recognizes(
      { controller: "public/links", action: "open_app_link", value: "x" },
      { path: "http://api.acme-custom.com/x", method: :get }
    )
  end

  test "preview.<custom-domain> routes to the public link handler, not the preview service" do
    assert_recognizes(
      { controller: "public/links", action: "open_app_link", value: "x" },
      { path: "http://preview.acme-custom.com/x", method: :get }
    )
  end

  test "go.<custom-domain> routes to the public link handler" do
    assert_recognizes(
      { controller: "public/links", action: "open_app_link", value: "x" },
      { path: "http://go.acme-custom.com/x", method: :get }
    )
  end

  # Regression: MAIN-domain reserved subdomains keep their routing.
  test "preview.sqd.link still routes to the preview service" do
    assert_recognizes(
      { controller: "public/links", action: "make_redirect", value: "x" },
      { path: "http://preview.sqd.link/x", method: :get }
    )
  end

  test "an ordinary custom subdomain still routes to the public link handler" do
    assert_recognizes(
      { controller: "public/links", action: "open_app_link", value: "x" },
      { path: "http://links.acme-custom.com/x", method: :get }
    )
  end

  # Regression (local dev): lvh.me is a MAIN host (a dev convenience — it and
  # *.lvh.me resolve to 127.0.0.1 with wildcard subdomains), so reserved subdomains
  # on it keep their routing instead of being treated as a custom domain. This is
  # what makes api.lvh.me reach the dashboard API; preview.lvh.me is the same check.
  test "preview.lvh.me routes to the preview service (lvh.me is a MAIN dev host)" do
    assert_recognizes(
      { controller: "public/links", action: "make_redirect", value: "x" },
      { path: "http://preview.lvh.me/x", method: :get }
    )
  end
end
