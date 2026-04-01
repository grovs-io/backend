require "test_helper"

class VerificationApiTest < ActionDispatch::IntegrationTest
  fixtures :instances, :projects, :domains, :applications, :ios_configurations,
           :android_configurations, :redirect_configs, :redirects,
           :ios_push_configurations, :android_push_configurations

  setup do
    @domain = domains(:one)
    @host = "#{@domain.subdomain}.#{@domain.domain}" # example.sqd.link
  end

  # --- iOS verification file ---

  test "iOS file returns correct appID format from fixture config" do
    get "/.well-known/apple-app-site-association", headers: { "Host" => @host }
    assert_response :ok

    json = JSON.parse(response.body)
    app_id = json["applinks"]["details"][0]["appID"]
    # From fixtures: app_prefix=ABC123, bundle_id=com.test.iosapp
    assert_equal "ABC123.com.test.iosapp", app_id
  end

  test "iOS file contains correct path patterns" do
    get "/.well-known/apple-app-site-association", headers: { "Host" => @host }
    assert_response :ok

    json = JSON.parse(response.body)
    paths = json["applinks"]["details"][0]["paths"]
    assert_includes paths, "/*"
    assert_includes paths, "NOT /_/*"
  end

  test "iOS file returns JSON content type" do
    get "/.well-known/apple-app-site-association", headers: { "Host" => @host }
    assert_response :ok
    assert_match "application/json", response.content_type
  end

  test "iOS returns 404 when domain not found" do
    get "/.well-known/apple-app-site-association", headers: { "Host" => "nonexistent.sqd.link" }
    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Domain not found", json["error"]
  end

  test "iOS returns 404 when instance has no iOS application" do
    # Instance two has no iOS app in applications fixture (second_ios_app belongs to instance two,
    # but domain two's project belongs to instance two which has second_ios_app)
    # Use a scenario where ios_application is nil — domain two's instance has an iOS app,
    # so we need to delete it
    Application.where(instance: instances(:two), platform: "ios").destroy_all

    host_two = "#{domains(:two).subdomain}.#{domains(:two).domain}"
    get "/.well-known/apple-app-site-association", headers: { "Host" => host_two }
    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Application not found", json["error"]
  end

  test "iOS returns 404 when ios_configuration missing" do
    # IosConfiguration#destroy cascades to delete the Application too,
    # so use delete_all to skip callbacks and only remove the config row
    IosPushConfiguration.where(ios_configuration: ios_configurations(:one)).delete_all
    IosConfiguration.where(id: ios_configurations(:one).id).delete_all
    Rails.cache.clear

    get "/.well-known/apple-app-site-association", headers: { "Host" => @host }
    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Configuration not set", json["error"]
  end

  test "iOS returns 404 when ios_phone redirect is disabled" do
    redirects(:ios_phone_redirect).update!(enabled: false)

    get "/.well-known/apple-app-site-association", headers: { "Host" => @host }
    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Configuration not enabled", json["error"]
  end

  # --- Android verification file ---

  test "Android file returns correct package_name and sha256 from fixture" do
    get "/.well-known/assetlinks.json", headers: { "Host" => @host }
    assert_response :ok

    json = JSON.parse(response.body)
    target = json[0]["target"]
    assert_equal "com.test.androidapp", target["package_name"]
    assert_equal ["AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"],
                 target["sha256_cert_fingerprints"]
  end

  test "Android file includes delegate_permission relation" do
    get "/.well-known/assetlinks.json", headers: { "Host" => @host }
    assert_response :ok

    json = JSON.parse(response.body)
    assert_equal ["delegate_permission/common.handle_all_urls"], json[0]["relation"]
  end

  test "Android returns 404 when domain not found" do
    get "/.well-known/assetlinks.json", headers: { "Host" => "nonexistent.sqd.link" }
    assert_response :not_found
  end

  test "Android returns 404 when no android application" do
    Application.where(instance: instances(:one), platform: "android").destroy_all

    get "/.well-known/assetlinks.json", headers: { "Host" => @host }
    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Application not found", json["error"]
  end

  test "Android returns 404 when android_configuration missing" do
    # AndroidConfiguration#destroy cascades to delete the Application via callback,
    # so remove FK dependents first, then delete the config row without callbacks
    config = android_configurations(:one)
    AndroidPushConfiguration.where(android_configuration_id: config.id).delete_all
    AndroidServerApiKey.where(android_configuration_id: config.id).delete_all
    AndroidConfiguration.where(id: config.id).delete_all
    Rails.cache.clear

    get "/.well-known/assetlinks.json", headers: { "Host" => @host }
    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Configuration not set", json["error"]
  end

  test "Android returns 404 when android_phone redirect is disabled" do
    redirects(:android_phone_redirect).update!(enabled: false)

    get "/.well-known/assetlinks.json", headers: { "Host" => @host }
    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Configuration not enabled", json["error"]
  end

  # --- BUG FINDER: mutable constant ---

  test "IOS_VERIFICATION_FILE is not corrupted across requests for different domains" do
    # First request: domain one (ABC123.com.test.iosapp)
    get "/.well-known/apple-app-site-association", headers: { "Host" => @host }
    assert_response :ok
    first_app_id = JSON.parse(response.body)["applinks"]["details"][0]["appID"]
    assert_equal "ABC123.com.test.iosapp", first_app_id

    # Set up domain two with different iOS config
    instance_two = instances(:two)
    # instance two already has second_ios_app but no ios_configuration for it
    second_ios_app = applications(:second_ios_app)
    IosConfiguration.create!(application: second_ios_app, bundle_id: "com.other.app", app_prefix: "XYZ789")

    # Domain two needs a redirect_config with enabled iOS redirect
    project_two = projects(:two)
    rc = RedirectConfig.find_or_create_by!(project: project_two)
    Redirect.create!(redirect_config: rc, application: second_ios_app, platform: "ios", variation: "phone", enabled: true)

    host_two = "#{domains(:two).subdomain}.#{domains(:two).domain}"
    get "/.well-known/apple-app-site-association", headers: { "Host" => host_two }
    assert_response :ok
    second_app_id = JSON.parse(response.body)["applinks"]["details"][0]["appID"]
    assert_equal "XYZ789.com.other.app", second_app_id

    # Third request back to domain one — if the constant was mutated, this returns the wrong appID
    get "/.well-known/apple-app-site-association", headers: { "Host" => @host }
    assert_response :ok
    third_app_id = JSON.parse(response.body)["applinks"]["details"][0]["appID"]
    assert_equal "ABC123.com.test.iosapp", third_app_id,
      "BUG: IOS_VERIFICATION_FILE constant is mutated between requests! " \
      "Third request returned '#{third_app_id}' instead of 'ABC123.com.test.iosapp'"
  end

  test "ANDROID_VERIFICATION_FILE is not corrupted across requests for different domains" do
    # First request: domain one
    get "/.well-known/assetlinks.json", headers: { "Host" => @host }
    assert_response :ok
    first_pkg = JSON.parse(response.body)[0]["target"]["package_name"]
    assert_equal "com.test.androidapp", first_pkg

    # Set up domain two with different Android config
    instance_two = instances(:two)
    android_app_two = Application.create!(instance: instance_two, platform: "android", enabled: true)
    AndroidConfiguration.create!(application: android_app_two, identifier: "com.other.android", sha256s: ["FF:EE:DD"])

    project_two = projects(:two)
    rc = RedirectConfig.find_or_create_by!(project: project_two)
    Redirect.create!(redirect_config: rc, application: android_app_two, platform: "android", variation: "phone", enabled: true)

    host_two = "#{domains(:two).subdomain}.#{domains(:two).domain}"
    get "/.well-known/assetlinks.json", headers: { "Host" => host_two }
    assert_response :ok
    second_pkg = JSON.parse(response.body)[0]["target"]["package_name"]
    assert_equal "com.other.android", second_pkg

    # Third request back to domain one
    get "/.well-known/assetlinks.json", headers: { "Host" => @host }
    assert_response :ok
    third_pkg = JSON.parse(response.body)[0]["target"]["package_name"]
    assert_equal "com.test.androidapp", third_pkg,
      "BUG: ANDROID_VERIFICATION_FILE constant is mutated between requests!"
  end
end
