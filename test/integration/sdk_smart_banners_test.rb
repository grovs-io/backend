require "test_helper"
require_relative "auth_test_helper"

class SdkSmartBannersTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include SmartBannerTestHelper

  fixtures :instances, :projects, :applications, :ios_configurations, :android_configurations,
           :web_configurations, :web_configuration_linked_domains, :devices, :visitors,
           :domains, :redirect_configs

  setup do
    @project = projects(:one)
    @headers = sdk_headers_for(@project, visitors(:ios_visitor), platform: "web", identifier: "app.example.com")
  end

  test "lists live banners in priority order" do
    second = create_test_banner(@project, name: "B", title: "Second", priority: 1, url_include: ["/products/*"])
    first = create_test_banner(@project, name: "A", title: "First", priority: 0, platforms: ["ios"])
    create_test_banner(@project, name: "Off", title: "Off", priority: 2, status: "paused")
    create_test_banner(projects(:two), name: "Other", title: "Other")

    get "#{SDK_PREFIX}/smart_banners", headers: @headers

    assert_response :ok
    banners = JSON.parse(response.body)["smart_banners"]
    assert_equal [first.id, second.id], banners.map { |b| b["id"] }
    assert_equal ["ios"], banners.first["platforms"]
    assert_equal ["/products/*"], banners.second["url_include"]
    assert_equal first.default_link.access_path, banners.first["default_link"]
    assert_nil banners.first["icon_url"]
  end

  test "a banner without a default link is skipped, not a 500" do
    ok = create_test_banner(@project, name: "A", title: "First", priority: 0)
    broken = create_test_banner(@project, name: "B", title: "Second", priority: 1)
    broken.update_column(:default_link_id, nil)

    get "#{SDK_PREFIX}/smart_banners", headers: @headers

    assert_response :ok
    banners = JSON.parse(response.body)["smart_banners"]
    assert_equal [ok.id], banners.map { |b| b["id"] }
  end

  test "an unlinked web domain is refused" do
    headers = @headers.merge("IDENTIFIER" => "evil.example.org")

    get "#{SDK_PREFIX}/smart_banners", headers: headers

    assert_response :unprocessable_entity
  end

  test "missing credentials are refused" do
    get "#{SDK_PREFIX}/smart_banners", headers: { "Host" => sdk_host }

    assert_response :forbidden
  end

  test "link returns the same url for the same page and a new one for another page" do
    banner = create_test_banner(@project)

    post "#{SDK_PREFIX}/smart_banners/#{banner.id}/link", params: { page_path: "/p/1", data: { sku: "A1" } },
         headers: @headers, as: :json
    assert_response :ok
    first = JSON.parse(response.body)["link"]

    post "#{SDK_PREFIX}/smart_banners/#{banner.id}/link", params: { page_path: "/p/1", data: { sku: "A1" } },
         headers: @headers, as: :json
    assert_equal first, JSON.parse(response.body)["link"]

    post "#{SDK_PREFIX}/smart_banners/#{banner.id}/link", params: { page_path: "/p/2" }, headers: @headers, as: :json
    assert_not_equal first, JSON.parse(response.body)["link"]

    link = Link.find_by(path: URI(first).path.delete_prefix("/"))
    assert_equal({ "page_path" => "/p/1", "sku" => "A1" }, link.data)
    assert_nil link.visitor_id
  end

  test "the new-link rate limit applies the same with a .json suffix on the path" do
    banner = create_test_banner(@project)

    SmartBannerLinkService.stub(:new_link_rate_limit, 1) do
      post "#{SDK_PREFIX}/smart_banners/#{banner.id}/link", params: { page_path: "/p/1" }, headers: @headers, as: :json
      assert_response :ok
      first = JSON.parse(response.body)["link"]

      post "#{SDK_PREFIX}/smart_banners/#{banner.id}/link.json", params: { page_path: "/p/2" },
           headers: @headers, as: :json
      assert_response :too_many_requests
      assert_equal "60", response.headers["Retry-After"]
      assert_not_equal first, banner.default_link.access_path
    end
  end

  test "the new-link rate limit returns 429 with Retry-After, not the default link" do
    banner = create_test_banner(@project)

    SmartBannerLinkService.stub(:new_link_rate_limit, 0) do
      post "#{SDK_PREFIX}/smart_banners/#{banner.id}/link", params: { page_path: "/p/1" }, headers: @headers, as: :json

      assert_response :too_many_requests
      assert_equal "60", response.headers["Retry-After"]
      assert_equal "Too many new links for this banner from this IP — try again in a minute",
                   JSON.parse(response.body)["error"]
    end
  end

  test "past the links cap, the link endpoint still returns 200 with the default link" do
    banner = create_test_banner(@project)

    SmartBannerLinkService.stub(:max_links, 0) do
      post "#{SDK_PREFIX}/smart_banners/#{banner.id}/link", params: { page_path: "/p/1" }, headers: @headers, as: :json

      assert_response :ok
      assert_equal banner.default_link.access_path, JSON.parse(response.body)["link"]
    end
  end

  test "link for a draft, paused, archived or foreign banner is 404" do
    draft = create_test_banner(@project, status: "draft")
    paused = create_test_banner(@project, status: "paused")
    archived = create_test_banner(@project, status: "archived")
    foreign = create_test_banner(projects(:two))

    [draft, paused, archived, foreign].each do |banner|
      post "#{SDK_PREFIX}/smart_banners/#{banner.id}/link", params: { page_path: "/p" }, headers: @headers, as: :json
      assert_response :not_found
    end
  end

  test "link for a banner deleted mid-request is 404, not a 500" do
    banner = create_test_banner(@project)
    deleted = ->(*) { raise ActiveRecord::InvalidForeignKey, "smart_banner_links_smart_banner_id_fkey" }

    SmartBannerLinkService.stub(:fetch, deleted) do
      post "#{SDK_PREFIX}/smart_banners/#{banner.id}/link", params: { page_path: "/p" }, headers: @headers, as: :json
    end

    assert_response :not_found
    assert JSON.parse(response.body)["error"].present?
  end

  test "link with invalid data is 422" do
    banner = create_test_banner(@project)

    post "#{SDK_PREFIX}/smart_banners/#{banner.id}/link", params: { page_path: "/p", data: { nested: { a: 1 } } },
         headers: @headers, as: :json

    assert_response :unprocessable_entity
    assert_match(/data values/, JSON.parse(response.body)["error"])
  end

  test "authenticate reports active banners to web only" do
    params = { vendor_id: "v-#{SecureRandom.hex(4)}", user_agent: "TestApp/2.0", app_version: "2.0" }
    web = sdk_auth_headers_for(@project, platform: "web", identifier: "app.example.com")
    ios = sdk_auth_headers_for(@project, platform: "ios")

    post "#{SDK_PREFIX}/authenticate", params: params, headers: web
    assert_response :ok
    assert_equal false, JSON.parse(response.body)["has_smart_banners"]

    create_test_banner(@project)
    post "#{SDK_PREFIX}/authenticate", params: params, headers: web
    assert_equal true, JSON.parse(response.body)["has_smart_banners"]

    post "#{SDK_PREFIX}/authenticate", params: params, headers: ios
    assert_response :ok
    assert_equal false, JSON.parse(response.body)["has_smart_banners"]
  end

  test "authenticate does not 500 when computing has_smart_banners raises" do
    params = { vendor_id: "v-#{SecureRandom.hex(4)}", user_agent: "TestApp/2.0", app_version: "2.0" }
    web = sdk_auth_headers_for(@project, platform: "web", identifier: "app.example.com")
    create_test_banner(@project)

    SmartBanner.stub(:sdk_payload_for, ->(*) { raise "boom" }) do
      post "#{SDK_PREFIX}/authenticate", params: params, headers: web
    end

    assert_response :ok
    assert_equal false, JSON.parse(response.body)["has_smart_banners"]
  end

  test "the banner endpoints are web only" do
    banner = create_test_banner(@project)
    ios = sdk_headers_for(@project, visitors(:ios_visitor), platform: "ios")

    get "#{SDK_PREFIX}/smart_banners", headers: ios
    assert_response :unprocessable_entity
    assert_equal "Smart banners are web only", JSON.parse(response.body)["error"]

    post "#{SDK_PREFIX}/smart_banners/#{banner.id}/link", params: { page_path: "/p" }, headers: ios, as: :json
    assert_response :unprocessable_entity
    assert_equal 0, banner.smart_banner_links.count
  end
end
