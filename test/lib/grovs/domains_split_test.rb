require "test_helper"

# Host splitting for self-hosted deployments where SERVER_HOST / link domains are
# nested (3+ labels, e.g. grovs.example.com) — Rails' request.domain/subdomain assume a
# 2-label registrable domain and misparse those hosts.
class GrovsDomainsSplitTest < ActiveSupport::TestCase
  include MainDomainsHelper

  NESTED_MAIN = ["links.example.com", "test.links.example.com", "grovs.example.com", "localhost"].freeze

  test "splits a reserved label off a nested SERVER_HOST" do
    with_main_domains(NESTED_MAIN) do
      assert_equal ["api", "grovs.example.com"], Grovs::Domains.split("api.grovs.example.com")
      assert_equal ["sdk", "grovs.example.com"], Grovs::Domains.split("sdk.grovs.example.com")
    end
  end

  test "splits a project label off a nested link domain" do
    with_main_domains(NESTED_MAIN) do
      assert_equal ["myapp", "links.example.com"], Grovs::Domains.split("myapp.links.example.com")
    end
  end

  test "longest matching MAIN suffix wins when one MAIN domain nests inside another" do
    with_main_domains(NESTED_MAIN) do
      assert_equal ["myapp", "test.links.example.com"], Grovs::Domains.split("myapp.test.links.example.com")
    end
  end

  test "apex of a MAIN domain splits to an empty label" do
    with_main_domains(NESTED_MAIN) do
      assert_equal ["", "grovs.example.com"], Grovs::Domains.split("grovs.example.com")
      assert_equal ["", "localhost"], Grovs::Domains.split("localhost")
    end
  end

  test "returns nil for hosts outside MAIN" do
    with_main_domains(NESTED_MAIN) do
      assert_nil Grovs::Domains.split("links.acme.com")
      assert_nil Grovs::Domains.split("api.acme.com")
      assert_nil Grovs::Domains.split("10.0.0.5")
    end
  end

  test "suffix match requires a label boundary, not a substring" do
    with_main_domains(["sqd.link"]) do
      assert_nil Grovs::Domains.split("notsqd.link")
    end
  end

  test "default 2-label MAIN domains split exactly like request.subdomain/domain did" do
    assert_equal ["example", "sqd.link"], Grovs::Domains.split("example.sqd.link")
    assert_equal ["a.b", "sqd.link"], Grovs::Domains.split("a.b.sqd.link")
    assert_equal ["", "sqd.link"], Grovs::Domains.split("sqd.link")
    assert_nil Grovs::Domains.split("acme-custom.com")
  end

  test "handles blank input" do
    assert_nil Grovs::Domains.split(nil)
    assert_nil Grovs::Domains.split("")
  end

  test "matches case-insensitively (DNS hostnames are case-insensitive)" do
    with_main_domains(NESTED_MAIN) do
      assert_equal ["api", "grovs.example.com"], Grovs::Domains.split("API.Grovs.EXAMPLE.com")
      assert_equal ["myapp", "links.example.com"], Grovs::Domains.split("MyApp.Links.example.COM")
    end
  end

  test "ignores a trailing DNS root dot" do
    with_main_domains(NESTED_MAIN) do
      assert_equal ["api", "grovs.example.com"], Grovs::Domains.split("api.grovs.example.com.")
    end
    assert_equal ["example", "sqd.link"], Grovs::Domains.split("example.sqd.link.")
  end

  test "normalize_env_host lowercases and strips scheme, path, port and root dot" do
    assert_equal "grovs.example.com", Grovs::Domains.normalize_env_host("https://Grovs.EXAMPLE.com:3000/x")
    assert_equal "links.example.com", Grovs::Domains.normalize_env_host("links.example.com.")
    assert_equal "lvh.me", Grovs::Domains.normalize_env_host("lvh.me:3000")
    assert_nil Grovs::Domains.normalize_env_host("")
    assert_nil Grovs::Domains.normalize_env_host(nil)
  end

  test "reserved-prefixed SERVER_HOST routes as its reserved label without claiming the parent zone" do
    with_main_domains(["api.acme.com"]) do
      assert_equal ["api", "acme.com"], Grovs::Domains.split("api.acme.com")
      assert_equal ["api", "acme.com"], Grovs::Domains.split("API.Acme.com")
      # The parent zone stays foreign — custom domains under it must keep resolving.
      assert_nil Grovs::Domains.split("deeplinks.acme.com")
      assert_nil Grovs::Domains.split("acme.com")
    end
  end

  test "SERVER_HOST shaped as <reserved>.<DOMAIN_LIVE> cannot shadow the reserved routing" do
    with_main_domains(["sqd.link", "api.sqd.link"]) do
      assert_equal ["api", "sqd.link"], Grovs::Domains.split("api.sqd.link")
      assert_equal ["sdk", "sqd.link"], Grovs::Domains.split("sdk.sqd.link")
    end
  end

  test "reserved-prefixed link domain: apex keeps its reserved routing, project hosts resolve" do
    with_main_domains(["links.example.com", "preview.links.example.com"]) do
      assert_equal ["preview", "links.example.com"], Grovs::Domains.split("preview.links.example.com")
      assert_equal ["myapp", "preview.links.example.com"], Grovs::Domains.split("myapp.preview.links.example.com")
    end
  end

  test "server_host_misconfiguration flags a reserved-prefixed SERVER_HOST" do
    original = ENV["SERVER_HOST"]

    ENV["SERVER_HOST"] = "api.grovs.example.com"
    message = Grovs::Domains.server_host_misconfiguration
    assert_match(/reserved subdomain 'api\.'/, message)
    assert_match(/grovs\.example\.com/, message)

    ENV["SERVER_HOST"] = "grovs.example.com"
    assert_nil Grovs::Domains.server_host_misconfiguration

    ENV["SERVER_HOST"] = nil
    assert_nil Grovs::Domains.server_host_misconfiguration
  ensure
    ENV["SERVER_HOST"] = original
  end
end
