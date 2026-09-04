require "test_helper"
require "webmock"

class SsoConnections::IssuerValidatorTest < ActiveSupport::TestCase
  setup do
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
    @self_hosted = ENV["GROVS_SELF_HOSTED"]
    ENV["GROVS_SELF_HOSTED"] = "false"
  end

  teardown do
    WebMock.reset!
    WebMock.disable!
    @self_hosted.nil? ? ENV.delete("GROVS_SELF_HOSTED") : ENV["GROVS_SELF_HOSTED"] = @self_hosted
  end

  def stub_discovery(issuer, body_issuer: issuer)
    WebMock.stub_request(:get, "#{issuer}/.well-known/openid-configuration").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { issuer: body_issuer, authorization_endpoint: "#{issuer}/authorize", token_endpoint: "#{issuer}/token",
              jwks_uri: "#{issuer}/keys", response_types_supported: ["code"], subject_types_supported: ["pairwise"],
              id_token_signing_alg_values_supported: ["RS256"] }.to_json
    )
  end

  test "non-https issuer" do
    assert_match(/https/, SsoConnections::IssuerValidator.error_for("http://idp.test"))
  end

  test "private address refused on SaaS, allowed self-hosted" do
    Resolv.stub(:getaddresses, ["10.0.0.5"]) do
      assert_match(/private/, SsoConnections::IssuerValidator.error_for("https://adfs.corp.internal"))
      ENV["GROVS_SELF_HOSTED"] = "true"
      stub_discovery("https://adfs.corp.internal")
      assert_nil SsoConnections::IssuerValidator.error_for("https://adfs.corp.internal")
    end
  end

  test "issuer mismatch in the document is refused without echoing the body" do
    Resolv.stub(:getaddresses, ["20.1.2.3"]) do
      stub_discovery("https://login.microsoftonline.com/common/v2.0", body_issuer: "https://login.microsoftonline.com/{tenantid}/v2.0")
      err = SsoConnections::IssuerValidator.error_for("https://login.microsoftonline.com/common/v2.0")
      assert_match(/discovery failed/, err)
      assert_no_match(/tenantid/, err)
    end
  end

  test "a discovered endpoint on a private address is refused on SaaS" do
    issuer = "https://idp.test/v2.0"
    WebMock.stub_request(:get, "#{issuer}/.well-known/openid-configuration").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { issuer: issuer, authorization_endpoint: "#{issuer}/authorize", token_endpoint: "https://metadata.internal/token",
              jwks_uri: "#{issuer}/keys", response_types_supported: ["code"], subject_types_supported: ["pairwise"],
              id_token_signing_alg_values_supported: ["RS256"] }.to_json
    )
    lookups = { "idp.test" => ["20.1.2.3"], "metadata.internal" => ["169.254.169.254"] }
    Resolv.stub(:getaddresses, ->(host) { lookups.fetch(host) }) do
      assert_match(/discovered endpoint/, SsoConnections::IssuerValidator.error_for(issuer))
    end
  end

  test "reachable matching issuer passes" do
    Resolv.stub(:getaddresses, ["20.1.2.3"]) do
      stub_discovery("https://idp.test/v2.0")
      assert_nil SsoConnections::IssuerValidator.error_for("https://idp.test/v2.0")
    end
  end
end
