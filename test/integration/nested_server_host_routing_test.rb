require "test_helper"

# Self-hosted deployments get nested domains (SERVER_HOST=grovs.example.com,
# DOMAIN_LIVE=links.example.com, DOMAIN_TEST=test.links.example.com). Reserved subdomains
# (api/sdk/go/preview/mcp) must keep routing to their handlers on those hosts, and
# link hosts must reach the public link handler — Rails' 2-label domain parsing
# used to send everything to the public handler instead.
class NestedServerHostRoutingTest < ActionDispatch::IntegrationTest
  include MainDomainsHelper

  NESTED_MAIN = ["links.example.com", "test.links.example.com", "grovs.example.com",
                 "localhost", "lvh.me"].freeze

  def with_nested_main(&block)
    with_main_domains(NESTED_MAIN, &block)
  end

  test "api.<nested SERVER_HOST> routes to the dashboard API" do
    with_nested_main do
      assert_recognizes(
        { controller: "api/v1/users", action: "create", format: :json },
        { path: "http://api.grovs.example.com/api/v1/users", method: :post }
      )
    end
  end

  test "sdk.<nested SERVER_HOST> routes to the SDK API" do
    with_nested_main do
      assert_recognizes(
        { controller: "api/v1/sdk/auth", action: "authenticate", format: :json },
        { path: "http://sdk.grovs.example.com/api/v1/sdk/authenticate", method: :post }
      )
    end
  end

  test "go.<nested SERVER_HOST> routes to the go link handler" do
    with_nested_main do
      assert_recognizes(
        { controller: "public/public_link", action: "get_link", path: "x" },
        { path: "http://go.grovs.example.com/x", method: :get }
      )
    end
  end

  test "preview.<nested SERVER_HOST> routes to the preview service" do
    with_nested_main do
      assert_recognizes(
        { controller: "public/links", action: "make_redirect", value: "x" },
        { path: "http://preview.grovs.example.com/x", method: :get }
      )
    end
  end

  test "mcp.<nested SERVER_HOST> routes to MCP" do
    with_nested_main do
      assert_recognizes(
        { controller: "mcp/oauth_metadata", action: "protected_resource" },
        { path: "http://mcp.grovs.example.com/.well-known/oauth-protected-resource", method: :get }
      )
    end
  end

  test "apex of a nested SERVER_HOST is not a public link host" do
    with_nested_main do
      assert_recognizes(
        { controller: "devise/sessions", action: "new" },
        { path: "http://grovs.example.com/users/sign_in", method: :get }
      )
    end
  end

  test "project subdomain on a nested DOMAIN_LIVE routes to the public link handler" do
    with_nested_main do
      assert_recognizes(
        { controller: "public/links", action: "open_app_link", value: "x" },
        { path: "http://myapp.links.example.com/x", method: :get }
      )
    end
  end

  test "project subdomain on a nested DOMAIN_TEST routes to the public link handler" do
    with_nested_main do
      assert_recognizes(
        { controller: "public/links", action: "open_app_link", value: "x" },
        { path: "http://myapp.test.links.example.com/x", method: :get }
      )
    end
  end

  test "AASA on a nested link domain routes to verification" do
    with_nested_main do
      assert_recognizes(
        { controller: "public/verification", action: "generate_ios_file" },
        { path: "http://myapp.links.example.com/.well-known/apple-app-site-association",
          method: :get }
      )
    end
  end

  test "reserved labels on a customer custom domain still route to the public handler" do
    with_nested_main do
      assert_recognizes(
        { controller: "public/links", action: "open_app_link", value: "x" },
        { path: "http://api.acme-custom.com/x", method: :get }
      )
    end
  end
end
