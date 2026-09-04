require "test_helper"

class GooglePubsubVerifierTest < ActiveSupport::TestCase
  test "verify returns nil for missing token" do
    assert_nil GooglePubsubVerifier.verify(nil)
    assert_nil GooglePubsubVerifier.verify("")
  end

  test "verify returns nil when certs fetch fails" do
    GooglePubsubVerifier.stub(:fetch_certs, nil) do
      result = GooglePubsubVerifier.verify("some.jwt.token")
      assert_nil result
    end
  end

  test "verify returns nil for invalid kid" do
    # Create a fake JWT with a kid not in certs
    header = Base64.urlsafe_encode64({ kid: "unknown_kid", alg: "RS256" }.to_json)
    payload = Base64.urlsafe_encode64({ sub: "test" }.to_json)
    fake_token = "#{header}.#{payload}.fakesignature"

    GooglePubsubVerifier.stub(:fetch_certs, { "known_kid" => "cert_data" }) do
      result = GooglePubsubVerifier.verify(fake_token)
      assert_nil result
    end
  end

  test "verify decodes valid token" do
    # Generate a real RSA key pair for testing
    rsa_key = OpenSSL::PKey::RSA.generate(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse("/CN=test")
    cert.issuer = cert.subject
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 3600
    cert.public_key = rsa_key.public_key
    cert.sign(rsa_key, OpenSSL::Digest.new('SHA256'))

    kid = "test_kid_123"
    token = JWT.encode(
      { sub: "test_subject", iss: "https://accounts.google.com", exp: Time.now.to_i + 3600 },
      rsa_key,
      "RS256",
      { kid: kid }
    )

    certs = { kid => cert.to_pem }

    GooglePubsubVerifier.stub(:fetch_certs, certs) do
      result = GooglePubsubVerifier.verify(token)
      assert result
      assert_equal "test_subject", result["sub"]
    end
  end

  # --- New: expired JWT, wrong issuer, network error, malformed token ---

  test "verify returns nil for expired JWT" do
    rsa_key, cert = generate_test_key_and_cert
    kid = "expired_kid"
    token = JWT.encode(
      { sub: "expired", iss: "https://accounts.google.com", exp: Time.now.to_i - 3600 },
      rsa_key, "RS256", { kid: kid }
    )
    certs = { kid => cert.to_pem }

    GooglePubsubVerifier.stub(:fetch_certs, certs) do
      assert_nil GooglePubsubVerifier.verify(token)
    end
  end

  test "verify returns nil for wrong issuer" do
    rsa_key, cert = generate_test_key_and_cert
    kid = "wrong_iss_kid"
    token = JWT.encode(
      { sub: "test", iss: "https://evil.example.com", exp: Time.now.to_i + 3600 },
      rsa_key, "RS256", { kid: kid }
    )
    certs = { kid => cert.to_pem }

    GooglePubsubVerifier.stub(:fetch_certs, certs) do
      assert_nil GooglePubsubVerifier.verify(token)
    end
  end

  test "verify returns nil when cert fetch returns nil (network error)" do
    # fetch_certs returns nil when network errors occur (timeout, etc.)
    # This test verifies verify() handles that gracefully
    GooglePubsubVerifier.stub(:fetch_certs, nil) do
      header = Base64.urlsafe_encode64({ kid: "some_kid", alg: "RS256" }.to_json)
      payload = Base64.urlsafe_encode64({ sub: "test" }.to_json)
      token = "#{header}.#{payload}.signature"
      assert_nil GooglePubsubVerifier.verify(token)
    end
  end

  test "verify returns nil for malformed token (not valid base64)" do
    GooglePubsubVerifier.stub(:fetch_certs, { "kid" => "cert" }) do
      assert_nil GooglePubsubVerifier.verify("not-valid-jwt")
    end
  end

  test "verify rejects a token whose audience differs from GOOGLE_PUBSUB_AUDIENCE" do
    rsa_key, cert = generate_test_key_and_cert
    token = signed_token(rsa_key, "aud_kid", aud: "https://attacker.example.com")

    with_env("GOOGLE_PUBSUB_AUDIENCE" => "https://api.sqd.link/iap/google") do
      GooglePubsubVerifier.stub(:fetch_certs, { "aud_kid" => cert.to_pem }) do
        assert_nil GooglePubsubVerifier.verify(token)
      end
    end
  end

  test "verify rejects a token whose email is not the expected service account" do
    rsa_key, cert = generate_test_key_and_cert
    token = signed_token(rsa_key, "email_kid", email: "attacker@evil.com", email_verified: true)

    with_env("GOOGLE_PUBSUB_SERVICE_ACCOUNT_EMAIL" => "push@proj.iam.gserviceaccount.com") do
      GooglePubsubVerifier.stub(:fetch_certs, { "email_kid" => cert.to_pem }) do
        assert_nil GooglePubsubVerifier.verify(token)
      end
    end
  end

  test "verify accepts a token matching the configured audience and service account" do
    rsa_key, cert = generate_test_key_and_cert
    token = signed_token(rsa_key, "ok_kid", aud: "aud-1",
                         email: "push@proj.iam.gserviceaccount.com", email_verified: true)

    with_env("GOOGLE_PUBSUB_AUDIENCE" => "aud-1",
             "GOOGLE_PUBSUB_SERVICE_ACCOUNT_EMAIL" => "push@proj.iam.gserviceaccount.com") do
      GooglePubsubVerifier.stub(:fetch_certs, { "ok_kid" => cert.to_pem }) do
        assert GooglePubsubVerifier.verify(token)
      end
    end
  end

  private

  def signed_token(rsa_key, kid, claims = {})
    payload = { iss: "https://accounts.google.com", exp: Time.now.to_i + 3600 }.merge(claims)
    JWT.encode(payload, rsa_key, "RS256", { kid: kid })
  end

  def with_env(vars)
    old = vars.transform_values { |_| nil }
    vars.each do |k, v| 
      old[k] = ENV[k]
      ENV[k] = v
    end
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  def generate_test_key_and_cert
    rsa_key = OpenSSL::PKey::RSA.generate(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse("/CN=test")
    cert.issuer = cert.subject
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 3600
    cert.public_key = rsa_key.public_key
    cert.sign(rsa_key, OpenSSL::Digest.new('SHA256'))
    [rsa_key, cert]
  end
end
