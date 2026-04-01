require "test_helper"

class LinkDisplayServiceTest < ActiveSupport::TestCase
  # LinkDisplayService now uses class methods directly

  def make_mock_domain(overrides = {})
    defaults = {
      generic_title: nil,
      generic_subtitle: nil,
      image_url: nil,
      full_domain: "test.sqd.link"
    }
    OpenStruct.new(defaults.merge(overrides))
  end

  def make_mock_link(overrides = {})
    domain = overrides.delete(:domain) || make_mock_domain
    defaults = {
      title: nil,
      subtitle: nil,
      image_resource: nil,
      access_path: "https://test.sqd.link/abc",
      tracking_campaign: nil,
      tracking_source: nil,
      tracking_medium: nil,
      domain: domain
    }
    OpenStruct.new(defaults.merge(overrides))
  end

  def make_device(bot: false)
    device = OpenStruct.new
    device.define_singleton_method(:bot?) { bot }
    device
  end

  # === generic_data_for_link — title ===

  test "generic_data uses default title when link and domain have none" do
    data = LinkDisplayService.generic_data_for_link(make_mock_link)
    assert_equal Grovs::Links::DEFAULT_TITLE, data[:page_title]
  end

  test "generic_data uses link title over domain title" do
    link = make_mock_link(
      title: "My Link Title",
      domain: make_mock_domain(generic_title: "Domain Title")
    )
    data = LinkDisplayService.generic_data_for_link(link)
    assert_equal "My Link Title", data[:page_title]
  end

  test "generic_data falls back to domain title when link title absent" do
    link = make_mock_link(domain: make_mock_domain(generic_title: "Domain Title"))
    data = LinkDisplayService.generic_data_for_link(link)
    assert_equal "Domain Title", data[:page_title]
  end

  # === generic_data_for_link — subtitle ===

  test "generic_data uses default subtitle when link and domain have none" do
    data = LinkDisplayService.generic_data_for_link(make_mock_link)
    assert_equal Grovs::Links::DEFAULT_SUBTITLE, data[:page_subtitle]
  end

  test "generic_data uses link subtitle over domain subtitle" do
    link = make_mock_link(
      subtitle: "Link Subtitle",
      domain: make_mock_domain(generic_subtitle: "Domain Subtitle")
    )
    data = LinkDisplayService.generic_data_for_link(link)
    assert_equal "Link Subtitle", data[:page_subtitle]
  end

  test "generic_data falls back to domain subtitle" do
    link = make_mock_link(domain: make_mock_domain(generic_subtitle: "Domain Subtitle"))
    data = LinkDisplayService.generic_data_for_link(link)
    assert_equal "Domain Subtitle", data[:page_subtitle]
  end

  # === generic_data_for_link — image ===

  test "generic_data uses default image when link and domain have none" do
    data = LinkDisplayService.generic_data_for_link(make_mock_link)
    assert_equal Grovs::Links::SOCIAL_PREVIEW, data[:page_image]
  end

  test "generic_data uses link image over domain image" do
    link = make_mock_link(
      image_resource: "https://example.com/link-image.png",
      domain: make_mock_domain(image_url: "https://example.com/domain-image.png")
    )
    data = LinkDisplayService.generic_data_for_link(link)
    assert_equal "https://example.com/link-image.png", data[:page_image]
  end

  test "generic_data falls back to domain image" do
    link = make_mock_link(domain: make_mock_domain(image_url: "https://example.com/domain-image.png"))
    data = LinkDisplayService.generic_data_for_link(link)
    assert_equal "https://example.com/domain-image.png", data[:page_image]
  end

  # === generic_data_for_link — path and domain ===

  test "generic_data returns correct page_full_path and domain" do
    data = LinkDisplayService.generic_data_for_link(make_mock_link)
    assert_equal "https://test.sqd.link/abc", data[:page_full_path]
    assert_equal "https://test.sqd.link", data[:domain]
  end

  # === generic_data_for_link — tracking ===

  test "generic_data builds tracking_data with compact removing nils" do
    link = make_mock_link(tracking_campaign: "summer", tracking_source: "email")
    data = LinkDisplayService.generic_data_for_link(link)

    assert_equal "summer", data[:tracking_campaign]
    assert_equal "email", data[:tracking_source]
    assert_nil data[:tracking_medium]
    assert_equal({ utm_source: "email", utm_campaign: "summer" }, data[:tracking_data])
  end

  test "generic_data returns empty tracking_data when all nil" do
    data = LinkDisplayService.generic_data_for_link(make_mock_link)
    assert_equal({}, data[:tracking_data])
  end

  test "generic_data includes all three tracking fields when present" do
    link = make_mock_link(tracking_campaign: "c", tracking_source: "s", tracking_medium: "m")
    data = LinkDisplayService.generic_data_for_link(link)
    assert_equal({ utm_source: "s", utm_medium: "m", utm_campaign: "c" }, data[:tracking_data])
  end

  # === should_log_view? ===

  test "should_log_view returns true for normal visit" do
    assert LinkDisplayService.should_log_view?(nil, make_device, nil)
  end

  test "should_log_view returns true when go_to_fallback is explicit false" do
    assert LinkDisplayService.should_log_view?(false, make_device, nil)
  end

  test "should_log_view returns false for bots" do
    assert_not LinkDisplayService.should_log_view?(nil, make_device(bot: true), nil)
  end

  test "should_log_view returns false when go_to_fallback is true" do
    assert_not LinkDisplayService.should_log_view?(true, make_device, nil)
  end

  test "should_log_view returns false when grovs_redirect present" do
    assert_not LinkDisplayService.should_log_view?(nil, make_device, "1")
  end

  # === fallback_url ===

  test "fallback_url returns appstore over fallback" do
    config = { phone: { "appstore" => "https://apps.apple.com/123", "fallback" => "https://example.com" } }
    assert_equal "https://apps.apple.com/123", LinkDisplayService.fallback_url(config)
  end

  test "fallback_url returns fallback when no appstore" do
    config = { phone: { "appstore" => nil, "fallback" => "https://example.com" } }
    assert_equal "https://example.com", LinkDisplayService.fallback_url(config)
  end

  test "fallback_url returns nil when phone and tablet are both nil" do
    assert_nil LinkDisplayService.fallback_url({ phone: nil, tablet: nil })
  end

  test "fallback_url falls back to tablet when phone is nil" do
    config = { phone: nil, tablet: { "fallback" => "https://tablet.example.com" } }
    assert_equal "https://tablet.example.com", LinkDisplayService.fallback_url(config)
  end

  test "fallback_url returns nil when config has no appstore or fallback" do
    config = { phone: { "appstore" => nil, "fallback" => nil } }
    assert_nil LinkDisplayService.fallback_url(config)
  end

  test "fallback_url returns nil for empty config hash" do
    assert_nil LinkDisplayService.fallback_url({})
  end
end
