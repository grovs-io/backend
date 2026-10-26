require "test_helper"
require_relative "auth_test_helper"

class SmartBannersApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include SmartBannerTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs,
           :applications, :web_configurations, :web_configuration_linked_domains

  setup do
    @project = projects(:one)
    @headers = doorkeeper_headers_for(users(:admin_user))
    @base = "#{API_PREFIX}/projects/#{@project.id}/smart_banners"
  end

  test "requires a token" do
    get @base, headers: api_headers

    assert_response :unauthorized
  end

  test "create with JSON returns the banner with default link and zero stats" do
    post @base, params: { smart_banner: valid_params }, headers: @headers, as: :json

    assert_response :created
    banner = JSON.parse(response.body)["smart_banner"]
    assert_equal "Main", banner["name"]
    assert_equal %w[ios], banner["platforms"]
    assert_equal ["/products/*"], banner["url_include"]
    assert_equal 0, banner["priority"]
    assert_match %r{\Ahttps://}, banner["default_link"]
    assert_equal 0, banner["stats"]["views"]
  end

  test "create with multipart uploads the icon and drops blank pattern entries" do
    post @base, params: { smart_banner: valid_params.merge(icon: png_upload, url_exclude: [""]) }, headers: @headers

    assert_response :created
    banner = JSON.parse(response.body)["smart_banner"]
    assert banner["icon_url"].present?
    assert_equal [], banner["url_exclude"]
  end

  test "invalid fields are 422 with the validation message" do
    post @base, params: { smart_banner: valid_params.merge(background_color: "red") }, headers: @headers, as: :json

    assert_response :unprocessable_entity
    assert_match(/Background color is invalid/, JSON.parse(response.body)["error"])
  end

  test "a member can manage banners" do
    post @base, params: { smart_banner: valid_params }, headers: doorkeeper_headers_for(users(:member_user)), as: :json

    assert_response :created
  end

  test "a project of another instance is forbidden" do
    get "#{API_PREFIX}/projects/#{projects(:two).id}/smart_banners", headers: @headers

    assert_response :forbidden
  end

  test "a banner of another project is not found" do
    foreign = create_test_banner(projects(:two))

    get "#{@base}/#{foreign.id}", headers: @headers

    assert_response :not_found
  end

  test "index and show return banners in priority order" do
    a = create_test_banner(@project, name: "A", priority: 1)
    b = create_test_banner(@project, name: "B", priority: 0)

    get @base, headers: @headers
    assert_response :ok
    assert_equal [b.id, a.id], JSON.parse(response.body)["smart_banners"].map { |x| x["id"] }

    get "#{@base}/#{a.id}", headers: @headers
    assert_response :ok
    assert_equal "A", JSON.parse(response.body)["smart_banner"]["name"]
  end

  test "a banner without a default link returns null instead of a 500" do
    banner = create_test_banner(@project)
    banner.update_column(:default_link_id, nil)

    get @base, headers: @headers
    assert_response :ok
    assert_nil JSON.parse(response.body)["smart_banners"].first["default_link"]

    get "#{@base}/#{banner.id}", headers: @headers
    assert_response :ok
    assert_nil JSON.parse(response.body)["smart_banner"]["default_link"]
  end

  test "update changes fields and can remove the icon" do
    banner = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "Old" }, icon: png_attachable)

    patch "#{@base}/#{banner.id}", params: { smart_banner: { title: "New", remove_icon: "true" } }, headers: @headers

    assert_response :ok
    body = JSON.parse(response.body)["smart_banner"]
    assert_equal "New", body["title"]
    assert_nil body["icon_url"]
  end

  test "open_hide_days round-trips through create and update" do
    post @base, params: { smart_banner: valid_params.merge(open_hide_days: 45) }, headers: @headers, as: :json
    assert_response :created
    banner = JSON.parse(response.body)["smart_banner"]
    assert_equal 45, banner["open_hide_days"]

    patch "#{@base}/#{banner['id']}", params: { smart_banner: { open_hide_days: 10 } }, headers: @headers, as: :json
    assert_response :ok
    assert_equal 10, JSON.parse(response.body)["smart_banner"]["open_hide_days"]
  end

  test "destroy removes the banner and keeps its links working" do
    banner = create_test_banner(@project)
    page_link = SmartBannerLinkService.fetch(banner, page_path: "/p/1", data: {})

    delete "#{@base}/#{banner.id}", headers: @headers

    assert_response :ok
    assert_equal({}, JSON.parse(response.body))
    assert_not SmartBanner.exists?(banner.id)
    assert Link.find(page_link.id).active
    assert Link.exists?(banner.default_link_id)
  end

  test "destroy locks the banner row before deleting it" do
    banner = create_test_banner(@project)
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      delete "#{@base}/#{banner.id}", headers: @headers
    end

    assert_response :ok
    lock_at = sql.index { |q| q.include?(%(FROM "smart_banners")) && q.include?("FOR UPDATE") }
    delete_at = sql.index { |q| q.start_with?(%(DELETE FROM "smart_banners")) }
    assert lock_at, "expected a SELECT ... FOR UPDATE on the banner"
    assert_operator lock_at, :<, delete_at
  end

  test "reorder sets the order and is not captured as a banner id" do
    a = create_test_banner(@project, name: "A", priority: 0)
    b = create_test_banner(@project, name: "B", priority: 1)

    patch "#{@base}/reorder", params: { ids: [b.id, a.id] }, headers: @headers, as: :json

    assert_response :ok
    assert_equal [b.id, a.id], JSON.parse(response.body)["smart_banners"].map { |x| x["id"] }
  end

  test "status reports configured domains and never-seen sdk" do
    get "#{@base}/status", headers: @headers

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal true, body["web_configured"]
    assert_equal %w[app.example.com www.example.com], body["domains"].sort
    assert_nil body["sdk_last_seen_at"]
  end

  test "status reports an unconfigured web app and reads the stamp fresh" do
    other_project = projects(:two)
    other_headers = doorkeeper_headers_for(users(:super_admin_user))
    Project.where(id: other_project.id).update_all(web_sdk_last_seen_at: Time.current)

    get "#{API_PREFIX}/projects/#{other_project.id}/smart_banners/status", headers: other_headers

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal false, body["web_configured"]
    assert_equal [], body["domains"]
    assert_in_delta Time.current, Time.iso8601(body["sdk_last_seen_at"]), 5.seconds
  end

  test "status for a project of another instance is forbidden" do
    get "#{API_PREFIX}/projects/#{projects(:two).id}/smart_banners/status", headers: @headers

    assert_response :forbidden
  end

  test "reorder with an incomplete list is 422" do
    a = create_test_banner(@project, name: "A")
    create_test_banner(@project, name: "B")

    patch "#{@base}/reorder", params: { ids: [a.id] }, headers: @headers, as: :json

    assert_response :unprocessable_entity
    assert_equal "ids must list every banner of the project exactly once", JSON.parse(response.body)["error"]
  end

  test "reorder excludes archived banners from the required list" do
    a = create_test_banner(@project, name: "A")
    b = create_test_banner(@project, name: "B")
    archived = create_test_banner(@project, name: "C", status: "archived")

    patch "#{@base}/reorder", params: { ids: [b.id, a.id] }, headers: @headers, as: :json

    assert_response :ok
    assert_equal [b.id, a.id], JSON.parse(response.body)["smart_banners"].map { |x| x["id"] }.excluding(archived.id)
  end

  test "create without status defaults to draft; paused and archived are refused" do
    post @base, params: { smart_banner: valid_params.except(:status) }, headers: @headers, as: :json
    assert_response :created
    assert_equal "draft", JSON.parse(response.body)["smart_banner"]["status"]

    %w[paused archived].each do |status|
      post @base, params: { smart_banner: valid_params.merge(status: status) }, headers: @headers, as: :json
      assert_response :unprocessable_entity
    end
  end

  test "status is writable on update, and restoring from archived forces paused at the end" do
    banner = create_test_banner(@project, name: "A")
    other = create_test_banner(@project, name: "B")

    patch "#{@base}/#{banner.id}", params: { smart_banner: { status: "archived" } }, headers: @headers, as: :json
    assert_response :ok
    assert_equal "archived", JSON.parse(response.body)["smart_banner"]["status"]
    assert_equal banner.reload.priority, JSON.parse(response.body)["smart_banner"]["priority"]

    patch "#{@base}/#{banner.id}", params: { smart_banner: { status: "live" } }, headers: @headers, as: :json
    assert_response :ok
    body = JSON.parse(response.body)["smart_banner"]
    assert_equal "paused", body["status"]
    assert_equal other.reload.priority + 1, body["priority"]
  end

  test "duplicate copies fields and icon into a draft banner with its own default link" do
    banner = SmartBannerManagementService.create(project: @project, attrs: { name: "A", title: "Old", status: "live" },
                                                 icon: png_attachable)
    create_test_banner(@project, name: "B")

    post "#{@base}/#{banner.id}/duplicate", headers: @headers

    assert_response :created
    copy = JSON.parse(response.body)["smart_banner"]
    assert_equal "A (copy)", copy["name"]
    assert_equal "draft", copy["status"]
    assert copy["icon_url"].present?
    assert copy["default_link"].present?
    assert_not_equal banner.default_link.access_path, copy["default_link"]
    assert_equal 1, copy["priority"]
  end

  test "duplicate of a foreign banner is not found" do
    foreign = create_test_banner(projects(:two))

    post "#{@base}/#{foreign.id}/duplicate", headers: @headers

    assert_response :not_found
  end

  private

  def valid_params
    { name: "Main", title: "Get the app", subtitle: "Faster in the app", button_text: "Open",
      platforms: ["ios"], url_include: ["/products/*"], url_exclude: [], position: "bottom",
      background_color: "#FFFFFF", text_color: "#111111", button_color: "#4F46E5",
      button_text_color: "#FFFFFF", dismiss_days: 7, open_hide_days: 30, status: "live" }
  end
end
