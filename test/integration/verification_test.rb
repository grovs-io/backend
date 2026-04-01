require "test_helper"

class VerificationTest < ActionDispatch::IntegrationTest
  fixtures :instances, :projects, :domains, :applications,
           :ios_configurations, :android_configurations,
           :redirect_configs, :redirects

  setup do
    @domain = domains(:one)
    @ios_config = ios_configurations(:one)
    @android_config = android_configurations(:one)
    # Save original constant values so we can detect mutation and restore after
    @original_ios_app_id = IOS_VERIFICATION_FILE[:applinks][:details][0][:appID].dup
    @original_android_pkg = ANDROID_VERIFICATION_FILE[:target][:package_name].dup
    @original_android_sha = ANDROID_VERIFICATION_FILE[:target][:sha256_cert_fingerprints].dup
  end

  teardown do
    # Restore mutated constants so other tests aren't affected
    IOS_VERIFICATION_FILE[:applinks][:details][0][:appID] = @original_ios_app_id
    ANDROID_VERIFICATION_FILE[:target][:package_name] = @original_android_pkg
    ANDROID_VERIFICATION_FILE[:target][:sha256_cert_fingerprints] = @original_android_sha
  end

  # --- iOS AASA ---

  test "iOS AASA returns correct appID for configured domain" do
    get "/.well-known/apple-app-site-association", headers: public_host_headers
    assert_response :ok
    json = JSON.parse(response.body)
    expected_app_id = "#{@ios_config.app_prefix}.#{@ios_config.bundle_id}"
    assert_equal expected_app_id, json["applinks"]["details"][0]["appID"]
  end

  test "iOS AASA returns 404 with error for domain without iOS app" do
    get "/.well-known/apple-app-site-association",
      headers: { "Host" => "#{domains(:two).subdomain}.#{domains(:two).domain}" }
    assert_response :not_found
    json = JSON.parse(response.body)
    assert json["error"].present?, "404 response should include an error message"
  end

  test "iOS AASA returns 404 when redirect not enabled" do
    redirect = Redirect.find_by(redirect_config: redirect_configs(:one), platform: "ios", variation: "phone")
    redirect.update_columns(enabled: false)

    get "/.well-known/apple-app-site-association", headers: public_host_headers
    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Configuration not enabled", json["error"]
  end

  # --- BUG: iOS AASA mutates global constant ---
  # VerificationController line 37-38 does `file = IOS_VERIFICATION_FILE` (alias, not copy)
  # then `file[:applinks][:details][0][:appID] = app_id` which mutates the global constant.
  # Under concurrent requests, this causes race conditions. Under sequential requests,
  # the constant permanently holds the last domain's appID instead of the initializer default.

  test "iOS AASA mutates the global IOS_VERIFICATION_FILE constant (known bug)" do
    get "/.well-known/apple-app-site-association", headers: public_host_headers
    assert_response :ok

    # After the request, the global constant holds this domain's appID.
    # A constant should never contain request-specific data — this proves
    # the controller mutates the shared constant on every request (line 37-38).
    domain_app_id = "#{@ios_config.app_prefix}.#{@ios_config.bundle_id}"
    assert_equal domain_app_id, IOS_VERIFICATION_FILE[:applinks][:details][0][:appID],
      "BUG: Global constant holds request-specific appID instead of being a template"
  end

  test "Android assetlinks mutates the global ANDROID_VERIFICATION_FILE constant (known bug)" do
    get "/.well-known/assetlinks.json", headers: public_host_headers
    assert_response :ok

    # Same bug: the global constant now holds this domain's package_name.
    assert_equal @android_config.identifier, ANDROID_VERIFICATION_FILE[:target][:package_name],
      "BUG: Global constant holds request-specific package_name instead of being a template"
  end

  # --- Android assetlinks ---

  test "Android assetlinks returns correct package_name and sha256" do
    get "/.well-known/assetlinks.json", headers: public_host_headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal @android_config.identifier, json[0]["target"]["package_name"]
    assert_equal @android_config.sha256s, json[0]["target"]["sha256_cert_fingerprints"]
  end

  test "Android assetlinks returns 404 with error for unknown domain" do
    get "/.well-known/assetlinks.json",
      headers: { "Host" => "#{domains(:two).subdomain}.#{domains(:two).domain}" }
    assert_response :not_found
    json = JSON.parse(response.body)
    assert json["error"].present?, "404 response should include an error message"
  end

  test "Android assetlinks returns 404 when redirect not enabled" do
    redirect = Redirect.find_by(redirect_config: redirect_configs(:one), platform: "android", variation: "phone")
    redirect.update_columns(enabled: false)

    get "/.well-known/assetlinks.json", headers: public_host_headers
    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Configuration not enabled", json["error"]
  end

  private

  def public_host_headers
    { "Host" => "#{@domain.subdomain}.#{@domain.domain}" }
  end
end
