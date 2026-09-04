require "test_helper"

class LinkAssetDefaultsTest < ActiveSupport::TestCase
  ENVIRONMENT_KEYS = %w[
    DEFAULT_LOGO_URL
    DEFAULT_SOCIAL_PREVIEW_URL
    SERVER_HOST
    SERVER_HOST_PROTOCOL
  ].freeze

  def with_env(overrides)
    saved = ENVIRONMENT_KEYS.index_with { |key| ENV[key] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "uses a bundled backend asset when an override is missing" do
    with_env(
      "DEFAULT_LOGO_URL" => nil,
      "SERVER_HOST" => "api.example.com",
      "SERVER_HOST_PROTOCOL" => "https://"
    ) do
      assert_equal(
        "https://api.example.com/assets/logo-square-black.png",
        Grovs.configured_link_asset_url("DEFAULT_LOGO_URL", "logo-square-black.png")
      )
    end
  end

  test "uses a bundled backend asset when an override is blank" do
    with_env(
      "DEFAULT_SOCIAL_PREVIEW_URL" => " ",
      "SERVER_HOST" => "api.example.com/",
      "SERVER_HOST_PROTOCOL" => "https"
    ) do
      assert_equal(
        "https://api.example.com/assets/logo-large-black.png",
        Grovs.configured_link_asset_url("DEFAULT_SOCIAL_PREVIEW_URL", "logo-large-black.png")
      )
    end
  end

  test "uses the configured URL when an override is provided" do
    with_env("DEFAULT_LOGO_URL" => "https://cdn.example.com/customer-logo.png") do
      assert_equal(
        "https://cdn.example.com/customer-logo.png",
        Grovs.configured_link_asset_url("DEFAULT_LOGO_URL", "logo-square-black.png")
      )
    end
  end
end
