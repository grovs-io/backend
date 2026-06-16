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

  # --- FIXED: AASA/assetlinks no longer mutate the global constants ---
  # VerificationController deep-dups IOS_VERIFICATION_FILE / ANDROID_VERIFICATION_FILE
  # before setting request-specific values, so the shared constants stay templates
  # (no cross-request leakage under concurrency).

  test "iOS AASA does not mutate the global IOS_VERIFICATION_FILE constant" do
    get "/.well-known/apple-app-site-association", headers: public_host_headers
    assert_response :ok

    domain_app_id = "#{@ios_config.app_prefix}.#{@ios_config.bundle_id}"
    assert_not_equal domain_app_id, IOS_VERIFICATION_FILE[:applinks][:details][0][:appID],
      "Global constant must remain a template, not hold request-specific appID"
  end

  test "Android assetlinks does not mutate the global ANDROID_VERIFICATION_FILE constant" do
    get "/.well-known/assetlinks.json", headers: public_host_headers
    assert_response :ok

    assert_not_equal @android_config.identifier, ANDROID_VERIFICATION_FILE[:target][:package_name],
      "Global constant must remain a template, not hold request-specific package_name"
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

# Mobile-SDK contract: AASA / assetlinks fetched on a CustomHostname must return the
# same appID / package_name as a fetch on the canonical *.sqd.link host. If this breaks
# silently, deep links stop opening apps for every customer on a custom domain.
class CustomHostVerificationTest < ActionDispatch::IntegrationTest
  fixtures :instances, :projects, :domains, :applications,
           :ios_configurations, :android_configurations,
           :redirect_configs, :redirects, :custom_hostnames

  setup do
    enable_custom_domains!
    @custom = custom_hostnames(:acme_active)
    @ios_config = ios_configurations(:one)
    @android_config = android_configurations(:one)
    # Tests are wrapped in transactions; after_commit hooks (which clear the model cache)
    # don't fire. Wipe the host's cache key at start so cross-test state doesn't leak.
    @custom.send(:clear_cache)
  end

  teardown do
    @custom&.send(:clear_cache)
    disable_custom_domains!
  end

  test "iOS AASA on a custom hostname returns the project's iOS appID" do
    get "/.well-known/apple-app-site-association", headers: { "Host" => @custom.hostname }
    assert_response :ok
    json = JSON.parse(response.body)
    expected_app_id = "#{@ios_config.app_prefix}.#{@ios_config.bundle_id}"
    assert_equal expected_app_id, json["applinks"]["details"][0]["appID"]
  end

  test "Android assetlinks on a custom hostname returns the project's package_name and sha256" do
    get "/.well-known/assetlinks.json", headers: { "Host" => @custom.hostname }
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal @android_config.identifier, json[0]["target"]["package_name"]
    assert_equal @android_config.sha256s, json[0]["target"]["sha256_cert_fingerprints"]
  end

  test "iOS AASA on a non-resolvable custom hostname returns 404" do
    @custom.update!(status: "suspended")
    get "/.well-known/apple-app-site-association", headers: { "Host" => @custom.hostname }
    assert_response :not_found
  end

  test "Android assetlinks on a non-resolvable custom hostname returns 404" do
    @custom.update!(status: "suspended")
    get "/.well-known/assetlinks.json", headers: { "Host" => @custom.hostname }
    assert_response :not_found
  end

  test "AASA on a custom hostname returns 404 when the feature flag is off" do
    disable_custom_domains!
    get "/.well-known/apple-app-site-association", headers: { "Host" => @custom.hostname }
    assert_response :not_found
  end
end
