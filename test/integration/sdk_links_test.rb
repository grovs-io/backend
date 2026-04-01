require "test_helper"
require_relative "auth_test_helper"

class SdkLinksTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects, :applications, :ios_configurations,
           :android_configurations, :devices, :visitors, :domains,
           :redirect_configs, :links

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)
    @headers = sdk_headers_for(@project, @visitor, platform: "ios")
  end

  # --- Unauthenticated ---

  test "create link without SDK headers returns 403 with no data" do
    post "#{SDK_PREFIX}/create_link",
      params: { title: "Test" },
      headers: { "Host" => sdk_host }
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_not json.key?("link"), "403 must not leak link data"
  end

  # --- Link Details ---

  test "link details for existing path returns correct link data" do
    post "#{SDK_PREFIX}/link_details",
      params: { path: @link.path },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal @link.path, json["path"], "must return correct path"
    assert_equal @link.title, json["title"], "must return correct title"
  end

  test "link details for nonexistent path returns null body" do
    post "#{SDK_PREFIX}/link_details",
      params: { path: "nonexistent-path-xyz" },
      headers: @headers
    assert_response :ok
    # Controller renders `render json: nil` for missing links
    parsed = JSON.parse(response.body) rescue nil
    assert_nil parsed, "nonexistent path must return null response"
  end

  # --- Create Link ---

  test "create link via SDK persists to DB and returns access path" do
    assert_difference "Link.count", 1 do
      post "#{SDK_PREFIX}/create_link",
        params: { title: "SDK Link", subtitle: "From SDK", user_agent: "TestApp/1.0" },
        headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert json["link"].present?, "must return link access path"

    created = Link.order(created_at: :desc).first
    assert_equal "SDK Link", created.title, "title must be persisted"
    assert_equal "From SDK", created.subtitle, "subtitle must be persisted"
    assert created.sdk_generated, "link must be marked as SDK generated"
    assert_equal @project.domain.id, created.domain_id, "link must belong to project domain"
  end

  # --- Data for Device ---

  test "data for device returns response with data and link keys" do
    post "#{SDK_PREFIX}/data_for_device",
      params: { user_agent: "TestApp/1.0" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Hash, json, "must return a hash response"
    # SdkLinkDataService returns {data:, link:, tracking:} — values may be nil
    assert json.key?("data"), "must include data key (may be null)"
    assert json.key?("link"), "must include link key (may be null)"
  end
end
