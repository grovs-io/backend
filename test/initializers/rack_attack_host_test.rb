require "test_helper"

class RackAttackHostTest < ActiveSupport::TestCase
  test "reserved_main_host? matches only our own reserved subdomains" do
    assert Rack::Attack.reserved_main_host?("api.sqd.link", Grovs::Subdomains::API)
    assert Rack::Attack.reserved_main_host?("sdk.sqd.link", Grovs::Subdomains::SDK)
    assert Rack::Attack.reserved_main_host?("mcp.sqd.link", Grovs::Subdomains::MCP)

    # Custom customer domains that merely start with a reserved label must NOT match,
    # so they fall through to the general public throttle instead of bypassing it.
    assert_not Rack::Attack.reserved_main_host?("api.acme.com", Grovs::Subdomains::API)
    assert_not Rack::Attack.reserved_main_host?("sdk.acme.com", Grovs::Subdomains::SDK)
    assert_not Rack::Attack.reserved_main_host?("apiary.acme.com", Grovs::Subdomains::API)
    assert_not Rack::Attack.reserved_main_host?(nil, Grovs::Subdomains::API)
    assert_not Rack::Attack.reserved_main_host?("", Grovs::Subdomains::API)
  end
end
