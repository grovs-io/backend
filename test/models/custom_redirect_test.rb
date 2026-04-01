require "test_helper"

class CustomRedirectTest < ActiveSupport::TestCase
  fixtures :domains, :projects, :redirect_configs, :instances

  setup do
    @link = Link.create!(
      domain: domains(:one),
      redirect_config: redirect_configs(:one),
      path: "custom-redirect-test",
      generated_from_platform: Grovs::Platforms::IOS
    )
  end

  # === validations: platform ===

  test "valid with valid platform" do
    redirect = CustomRedirect.new(link: @link, platform: Grovs::Platforms::IOS, url: "https://example.com")
    assert redirect.valid?
  end

  test "invalid without platform" do
    redirect = CustomRedirect.new(link: @link, platform: nil, url: "https://example.com")
    assert_not redirect.valid?
    assert redirect.errors[:platform].any?
  end

  test "invalid with platform not in ALL" do
    redirect = CustomRedirect.new(link: @link, platform: "invalid_platform", url: "https://example.com")
    assert_not redirect.valid?
    assert redirect.errors[:platform].any?
  end

  test "valid for each platform in ALL" do
    Grovs::Platforms::ALL.each do |platform|
      redirect = CustomRedirect.new(link: @link, platform: platform, url: "https://example.com/#{platform}")
      # Need to ensure uniqueness: only first one per platform will pass
      assert redirect.valid?, "Expected valid for platform=#{platform}"
      redirect.save!
    end
  end

  # === validations: url ===

  test "invalid without url" do
    redirect = CustomRedirect.new(link: @link, platform: Grovs::Platforms::IOS, url: nil)
    assert_not redirect.valid?
    assert_includes redirect.errors[:url], "can't be blank"
  end

  test "invalid with blank url" do
    redirect = CustomRedirect.new(link: @link, platform: Grovs::Platforms::IOS, url: "")
    assert_not redirect.valid?
    assert_includes redirect.errors[:url], "can't be blank"
  end

  # === validations: link_id uniqueness scoped to platform ===

  test "invalid with duplicate link_id and platform" do
    CustomRedirect.create!(link: @link, platform: Grovs::Platforms::ANDROID, url: "https://example.com/first")

    duplicate = CustomRedirect.new(link: @link, platform: Grovs::Platforms::ANDROID, url: "https://example.com/second")
    assert_not duplicate.valid?
    assert duplicate.errors[:link_id].any?
  end

  test "valid with same link_id but different platform" do
    CustomRedirect.create!(link: @link, platform: Grovs::Platforms::IOS, url: "https://example.com/ios")

    redirect = CustomRedirect.new(link: @link, platform: Grovs::Platforms::ANDROID, url: "https://example.com/android")
    assert redirect.valid?
  end

  # === serialization ===

  test "serializer excludes created_at, updated_at, id, link_id, and platform" do
    redirect = CustomRedirect.create!(link: @link, platform: Grovs::Platforms::DESKTOP, url: "https://example.com/desktop")
    json = CustomRedirectSerializer.serialize(redirect)

    assert_not json.key?("created_at")
    assert_not json.key?("updated_at")
    assert_not json.key?("id")
    assert_not json.key?("link_id")
    assert_not json.key?("platform")
  end

  test "serializer includes url and open_app_if_installed" do
    redirect = CustomRedirect.create!(link: @link, platform: Grovs::Platforms::WEB, url: "https://example.com/web")
    json = CustomRedirectSerializer.serialize(redirect)

    assert_equal "https://example.com/web", json["url"]
    assert json.key?("open_app_if_installed")
  end
end
