require "test_helper"

class SdkLinkBuilderTest < ActiveSupport::TestCase
  include SdkLinkBuilder
  include CustomRedirectsHandler

  fixtures :instances, :projects, :domains, :redirect_configs, :links

  setup do
    @project = projects(:one)
    @_stubbed_params = {}
  end

  # ---------------------------------------------------------------------------
  # Basic link creation
  # ---------------------------------------------------------------------------

  test "creates a persisted link with required attributes" do
    stub_params(title: "My Link", subtitle: "A description")

    link = build_and_save_sdk_link(platform_name: "ios")

    assert link.persisted?
    assert_equal "My Link", link.title
    assert_equal "A description", link.subtitle
    assert_equal "ios", link.generated_from_platform
    assert link.sdk_generated
    assert_equal @project.domain_for_project, link.domain
    assert_equal @project.redirect_config, link.redirect_config
  end

  test "retries with a fresh path when another writer takes it first" do
    stub_params(title: "Racing link")
    paths = [links(:basic_link).path, "f4e2b1"]

    LinksService.stub(:generate_valid_path, ->(_domain) { paths.shift }) do
      link = build_and_save_sdk_link(platform_name: "ios")

      assert link.persisted?
      assert_equal "f4e2b1", link.path
    end
  end

  test "gives up after repeated path collisions rather than retrying forever" do
    stub_params(title: "Hopeless link")
    taken = links(:basic_link).path

    LinksService.stub(:generate_valid_path, ->(_domain) { taken }) do
      assert_raises(LinksService::PathGenerationError) do
        build_and_save_sdk_link(platform_name: "ios")
      end
    end
  end

  test "generates a unique path on the domain" do
    stub_params(title: "Path Test")

    link = build_and_save_sdk_link(platform_name: "android")

    assert link.path.present?
    assert_equal 1, Link.where(domain: link.domain, path: link.path).count
  end

  # ---------------------------------------------------------------------------
  # Optional attributes
  # ---------------------------------------------------------------------------

  test "sets visitor when provided" do
    visitor = Visitor.create!(
      project: @project,
      device: Device.create!(platform: "ios", user_agent: "Test/1", ip: "1.1.1.1", remote_ip: "1.1.1.1"),
      web_visitor: false
    )
    stub_params(title: "Visitor Link")

    link = build_and_save_sdk_link(platform_name: "ios", visitor: visitor)

    assert_equal visitor.id, link.visitor_id
  end

  test "sets image_url when provided" do
    stub_params(title: "Image URL Link")

    link = build_and_save_sdk_link(platform_name: "ios", image_url: "https://cdn.example.com/img.png")

    assert_equal "https://cdn.example.com/img.png", link.image_url
  end

  test "stores parsed JSON data" do
    stub_params(title: "Data Link", data: '[{"key":"promo","value":"50off"}]')

    link = build_and_save_sdk_link(platform_name: "ios")

    assert_equal [{ "key" => "promo", "value" => "50off" }], link.data
  end

  test "stores parsed JSON tags" do
    stub_params(title: "Tagged Link", tags: '["summer","sale"]')

    link = build_and_save_sdk_link(platform_name: "web")

    assert_equal ["summer", "sale"], link.tags
  end

  test "sets tracking fields" do
    stub_params(
      title: "Tracked Link",
      tracking_campaign: "black-friday",
      tracking_source: "email",
      tracking_medium: "newsletter"
    )

    link = build_and_save_sdk_link(platform_name: "ios")

    assert_equal "black-friday", link.tracking_campaign
    assert_equal "email", link.tracking_source
    assert_equal "newsletter", link.tracking_medium
  end

  # ---------------------------------------------------------------------------
  # show_preview flags
  # ---------------------------------------------------------------------------

  test "show_preview sets both iOS and Android" do
    stub_params(title: "Preview Link", show_preview: false)

    link = build_and_save_sdk_link(platform_name: "ios")

    assert_equal false, link.show_preview_ios
    assert_equal false, link.show_preview_android
  end

  test "show_preview_ios overrides the global show_preview for iOS" do
    stub_params(title: "iOS Override", show_preview: false, show_preview_ios: true)

    link = build_and_save_sdk_link(platform_name: "ios")

    assert_equal true, link.show_preview_ios
    assert_equal false, link.show_preview_android
  end

  test "show_preview_android overrides the global show_preview for Android" do
    stub_params(title: "Android Override", show_preview: true, show_preview_android: false)

    link = build_and_save_sdk_link(platform_name: "android")

    assert_equal true, link.show_preview_ios
    assert_equal false, link.show_preview_android
  end

  test "copy_to_clipboard params set the per-platform toggles" do
    stub_params(title: "Copy Link", copy_to_clipboard_ios: true, copy_to_clipboard_android: false)

    link = build_and_save_sdk_link(platform_name: "ios")

    assert_equal true, link.copy_to_clipboard_ios
    assert_equal false, link.copy_to_clipboard_android
  end

  test "copy_to_clipboard params left out keep the tri-state nil" do
    stub_params(title: "No Copy Params")

    link = build_and_save_sdk_link(platform_name: "ios")

    assert_nil link.copy_to_clipboard_ios
    assert_nil link.copy_to_clipboard_android
  end

  # ---------------------------------------------------------------------------
  # Custom redirects integration
  # ---------------------------------------------------------------------------

  test "creates custom redirects when params provided" do
    stub_params(
      title: "Redirect Link",
      ios_custom_redirect: { "url" => "https://appstore.com/app", "open_app_if_installed" => true },
      android_custom_redirect: nil,
      desktop_custom_redirect: nil
    )

    link = build_and_save_sdk_link(platform_name: "ios")

    assert_equal "https://appstore.com/app", link.ios_custom_redirect.url
  end

  # ---------------------------------------------------------------------------
  # Nil optional params don't break creation
  # ---------------------------------------------------------------------------

  test "creates link with all optional params nil" do
    stub_params({})

    link = build_and_save_sdk_link(platform_name: "desktop")

    assert link.persisted?
    assert_nil link.title
    assert_nil link.subtitle
    assert_nil link.data
    assert_equal [], link.tags  # PostgreSQL array column defaults to []
    assert_nil link.tracking_campaign
    assert link.sdk_generated
  end

  private

  # Simulate controller params for the modules
  def stub_params(hash)
    @_stubbed_params = ActionController::Parameters.new(hash)
  end

  def params
    @_stubbed_params || ActionController::Parameters.new
  end

  # Param accessor methods (normally defined in the controller)
  def title_param          = params.permit(:title)[:title]
  def subtitle_param       = params.permit(:subtitle)[:subtitle]
  def data_param           = params.permit(:data)[:data]
  def tags_param           = params.permit(:tags)[:tags]
  def show_preview_param   = params.permit(:show_preview)[:show_preview]
  def show_preview_ios_param     = params.permit(:show_preview_ios)[:show_preview_ios]
  def show_preview_android_param = params.permit(:show_preview_android)[:show_preview_android]
  def copy_to_clipboard_ios_param = params.permit(:copy_to_clipboard_ios)[:copy_to_clipboard_ios]
  def copy_to_clipboard_android_param = params.permit(:copy_to_clipboard_android)[:copy_to_clipboard_android]
  def tracking_campaign_param    = params.permit(:tracking_campaign)[:tracking_campaign]
  def tracking_source_param      = params.permit(:tracking_source)[:tracking_source]
  def tracking_medium_param      = params.permit(:tracking_medium)[:tracking_medium]
end
