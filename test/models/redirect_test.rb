require "test_helper"

class RedirectTest < ActiveSupport::TestCase
  fixtures :redirects, :redirect_configs, :applications, :instances, :projects

  # === platform validation ===

  test "valid with a recognized platform" do
    redirect = redirects(:ios_phone_redirect)
    assert redirect.valid?
  end

  test "invalid with unrecognized platform" do
    redirect = redirects(:ios_phone_redirect)
    redirect.platform = "unknown_platform"
    assert_not redirect.valid?
    assert redirect.errors[:platform].any?
  end

  Grovs::Platforms::ALL.each do |platform|
    test "accepts platform #{platform}" do
      redirect = Redirect.new(
        redirect_config: redirect_configs(:one),
        application: applications(:ios_app),
        platform: platform,
        variation: Grovs::Platforms::PHONE,
        appstore: false,
        fallback_url: "https://example.com"
      )
      assert redirect.valid?, "Expected platform '#{platform}' to be valid, errors: #{redirect.errors.full_messages}"
    end
  end

  # === variation validation ===

  test "invalid with unrecognized variation" do
    redirect = redirects(:ios_phone_redirect)
    redirect.variation = "unknown_variation"
    assert_not redirect.valid?
    assert redirect.errors[:variation].any?
  end

  Grovs::Platforms::VARIATIONS.each do |variation|
    test "accepts variation #{variation}" do
      redirect = Redirect.new(
        redirect_config: redirect_configs(:one),
        application: applications(:ios_app),
        platform: Grovs::Platforms::IOS,
        variation: variation,
        appstore: true,
        fallback_url: nil
      )
      assert redirect.valid?, "Expected variation '#{variation}' to be valid, errors: #{redirect.errors.full_messages}"
    end
  end

  # === fallback_must_be_consistent ===

  test "valid when appstore is true and fallback_url is nil" do
    redirect = redirects(:ios_phone_redirect)
    redirect.appstore = true
    redirect.fallback_url = nil
    assert redirect.valid?
  end

  test "valid when appstore is false and fallback_url is present" do
    redirect = redirects(:android_phone_redirect)
    redirect.appstore = false
    redirect.fallback_url = "https://example.com/fallback"
    assert redirect.valid?
  end

  test "invalid when appstore is false and fallback_url is nil" do
    redirect = redirects(:ios_phone_redirect)
    redirect.appstore = false
    redirect.fallback_url = nil
    assert_not redirect.valid?
    assert redirect.errors[:fallback].include?("fallback missing")
  end

  test "invalid when appstore is true and fallback_url is present" do
    redirect = redirects(:ios_phone_redirect)
    redirect.appstore = true
    redirect.fallback_url = "https://example.com/fallback"
    assert_not redirect.valid?
    assert redirect.errors[:fallback].include?("fallback won't be executed")
  end

  # === serialization ===

  test "serializer excludes internal fields" do
    redirect = redirects(:android_phone_redirect)
    json = RedirectSerializer.serialize(redirect)
    assert_nil json["id"]
    assert_nil json["created_at"]
    assert_nil json["updated_at"]
    assert_nil json["application_id"]
  end

  test "serializer includes redirect fields" do
    redirect = redirects(:android_phone_redirect)
    json = RedirectSerializer.serialize(redirect)
    assert_equal "android", json["platform"]
    assert_equal "phone", json["variation"]
    assert_equal false, json["appstore"]
    assert_equal "https://example.com/fallback", json["fallback_url"]
  end
end
