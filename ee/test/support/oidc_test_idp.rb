require "webmock"

module OidcTestIdp
  ISSUER = "https://idp.test/v2.0".freeze
  KEY = OpenSSL::PKey::RSA.new(2048)
  JWK = JSON::JWK.new(KEY, kid: "k1")
  CLIENT_ID = "cid".freeze

  module_function

  def enable!
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
    WebMock.stub_request(:get, "#{ISSUER}/.well-known/openid-configuration").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { issuer: ISSUER, authorization_endpoint: "https://idp.test/authorize", token_endpoint: "https://idp.test/token",
              userinfo_endpoint: "https://idp.test/userinfo", jwks_uri: "https://idp.test/keys",
              response_types_supported: ["code"], subject_types_supported: ["pairwise"],
              id_token_signing_alg_values_supported: ["RS256"] }.to_json
    )
    stub_jwks!(JWK)
    WebMock.stub_request(:get, "https://idp.test/userinfo").to_return(
      status: 200, headers: { "Content-Type" => "application/json" }, body: { sub: "ignored-by-merge" }.to_json
    )
  end

  def disable!
    WebMock.reset!
    WebMock.disable!
  end

  def stub_jwks!(jwk)
    WebMock.stub_request(:get, "https://idp.test/keys").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { keys: [JSON::JWK.new(jwk.to_key.public_key, kid: jwk[:kid])] }.to_json
    )
  end

  def stub_token!(id_token)
    WebMock.stub_request(:post, "https://idp.test/token").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { access_token: "at", token_type: "Bearer", expires_in: 3600, id_token: id_token }.to_json
    )
  end

  def mint(nonce:, sub: "sub-1", email: "alice@example.com", name: "Alice", key: JWK, alg: :RS256, **extra)
    now = Time.now.to_i
    claims = { iss: ISSUER, aud: CLIENT_ID, sub: sub, exp: now + 300, iat: now, nonce: nonce, name: name }
    claims[:email] = email if email
    claims.merge!(extra)
    JSON::JWT.new(claims).sign(key, alg).to_s
  end
end
