require "test_helper"

class CustomRedirectsHandlerTest < ActiveSupport::TestCase
  include CustomRedirectsHandler

  fixtures :instances, :projects, :domains, :links, :redirect_configs, :custom_redirects

  setup do
    @link = links(:basic_link)
    # Start each test with a clean slate — destroy fixture redirects
    @link.custom_redirects.destroy_all
  end

  # ---------------------------------------------------------------------------
  # update_custom_redirects_for_link — creates redirects for all 3 platforms
  # ---------------------------------------------------------------------------

  test "creates iOS, Android, and Desktop redirects when all params present" do
    stub_params(
      ios_custom_redirect: { "url" => "https://apps.apple.com/app/123", "open_app_if_installed" => true },
      android_custom_redirect: { "url" => "https://play.google.com/store/apps/details?id=com.test", "open_app_if_installed" => false },
      desktop_custom_redirect: { "url" => "https://example.com/desktop" }
    )

    assert_difference "CustomRedirect.count", 3 do
      update_custom_redirects_for_link(@link)
    end

    assert_equal "https://apps.apple.com/app/123", @link.ios_custom_redirect.url
    assert @link.ios_custom_redirect.open_app_if_installed

    assert_equal "https://play.google.com/store/apps/details?id=com.test", @link.android_custom_redirect.url
    assert_not @link.android_custom_redirect.open_app_if_installed

    assert_equal "https://example.com/desktop", @link.desktop_custom_redirect.url
    assert_not @link.desktop_custom_redirect.open_app_if_installed
  end

  # ---------------------------------------------------------------------------
  # Destroy-and-recreate behavior
  # ---------------------------------------------------------------------------

  test "replaces existing redirect when new URL provided" do
    CustomRedirect.create!(link: @link, platform: "ios", url: "https://old-url.com", open_app_if_installed: false)
    @link.reload

    stub_params(
      ios_custom_redirect: { "url" => "https://new-url.com", "open_app_if_installed" => true },
      android_custom_redirect: nil,
      desktop_custom_redirect: nil
    )

    update_custom_redirects_for_link(@link)

    assert_equal 1, @link.custom_redirects.reload.count
    assert_equal "https://new-url.com", @link.ios_custom_redirect.url
    assert @link.ios_custom_redirect.open_app_if_installed
  end

  test "destroys existing redirect when param is nil" do
    CustomRedirect.create!(link: @link, platform: "ios", url: "https://old-url.com", open_app_if_installed: true)
    @link.reload

    stub_params(
      ios_custom_redirect: nil,
      android_custom_redirect: nil,
      desktop_custom_redirect: nil
    )

    assert_difference "CustomRedirect.count", -1 do
      update_custom_redirects_for_link(@link)
    end

    assert_nil @link.reload.ios_custom_redirect
  end

  # ---------------------------------------------------------------------------
  # Selective platform updates — only changes specified platforms
  # ---------------------------------------------------------------------------

  test "creates only iOS redirect when others are nil" do
    stub_params(
      ios_custom_redirect: { "url" => "https://ios-only.com", "open_app_if_installed" => true },
      android_custom_redirect: nil,
      desktop_custom_redirect: nil
    )

    assert_difference "CustomRedirect.count", 1 do
      update_custom_redirects_for_link(@link)
    end

    assert_not_nil @link.ios_custom_redirect
    assert_nil @link.android_custom_redirect
    assert_nil @link.desktop_custom_redirect
  end

  # ---------------------------------------------------------------------------
  # Transaction atomicity
  # ---------------------------------------------------------------------------

  test "rolls back all changes if one platform fails" do
    CustomRedirect.create!(link: @link, platform: "ios", url: "https://existing.com", open_app_if_installed: true)
    @link.reload

    stub_params(
      ios_custom_redirect: { "url" => "https://new-ios.com", "open_app_if_installed" => true },
      android_custom_redirect: { "url" => "", "open_app_if_installed" => false }, # blank url will fail validation
      desktop_custom_redirect: nil
    )

    assert_raises(ActiveRecord::RecordInvalid) do
      update_custom_redirects_for_link(@link)
    end

    # iOS redirect should still be the original (transaction rolled back)
    @link.custom_redirects.reload
    ios = @link.ios_custom_redirect
    assert_not_nil ios
    assert_equal "https://existing.com", ios.url
  end

  # ---------------------------------------------------------------------------
  # parse_custom_redirect_param — JSON string input
  # ---------------------------------------------------------------------------

  test "parses stringified JSON for iOS param" do
    stub_params(
      ios_custom_redirect: '{"url":"https://from-json.com","open_app_if_installed":true}',
      android_custom_redirect: nil,
      desktop_custom_redirect: nil
    )

    update_custom_redirects_for_link(@link)

    assert_equal "https://from-json.com", @link.ios_custom_redirect.url
  end

  test "returns nil for invalid JSON string" do
    stub_params(
      ios_custom_redirect: "not-json{{{",
      android_custom_redirect: nil,
      desktop_custom_redirect: nil
    )

    # Should not create any redirects (invalid JSON → nil → destroy path)
    assert_no_difference "CustomRedirect.count" do
      update_custom_redirects_for_link(@link)
    end
  end

  # ---------------------------------------------------------------------------
  # Desktop has no open_app_if_installed requirement
  # ---------------------------------------------------------------------------

  test "desktop param does not require open_app_if_installed" do
    stub_params(
      ios_custom_redirect: nil,
      android_custom_redirect: nil,
      desktop_custom_redirect: { "url" => "https://desktop.com" }
    )

    assert_difference "CustomRedirect.count", 1 do
      update_custom_redirects_for_link(@link)
    end

    assert_equal "https://desktop.com", @link.desktop_custom_redirect.url
  end

  test "iOS param returns nil when open_app_if_installed missing" do
    stub_params(
      ios_custom_redirect: { "url" => "https://ios.com" }, # missing open_app_if_installed
      android_custom_redirect: nil,
      desktop_custom_redirect: nil
    )

    # iOS should be treated as nil → no redirect created
    assert_no_difference "CustomRedirect.count" do
      update_custom_redirects_for_link(@link)
    end
  end

  # ---------------------------------------------------------------------------
  # ActionController::Parameters input
  # ---------------------------------------------------------------------------

  test "handles ActionController::Parameters input" do
    stub_params(
      ios_custom_redirect: ActionController::Parameters.new(
        "url" => "https://from-params.com", "open_app_if_installed" => true
      ),
      android_custom_redirect: nil,
      desktop_custom_redirect: nil
    )

    update_custom_redirects_for_link(@link)

    assert_equal "https://from-params.com", @link.ios_custom_redirect.url
  end

  private

  # Simulate controller params for the module
  def stub_params(**overrides)
    @_stubbed_params = ActionController::Parameters.new(overrides)
  end

  def params
    @_stubbed_params || ActionController::Parameters.new
  end
end
