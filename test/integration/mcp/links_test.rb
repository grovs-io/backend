require "test_helper"
require_relative "../mcp_auth_test_helper"

class McpLinksTest < ActionDispatch::IntegrationTest
  include McpAuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :links, :campaigns, :link_daily_statistics

  setup do
    @admin_user = users(:admin_user)
    @member_user = users(:member_user)
    @instance = instances(:one)
    @project = projects(:one)
    @link = links(:basic_link)
    @inactive_link = links(:inactive_link)
    @admin_headers = create_mcp_headers_for(@admin_user)
    @member_headers = create_mcp_headers_for(@member_user)
  end

  # ==========================================================================
  # Forbidden Access (BaseController helpers)
  # ==========================================================================

  test "forbidden when user is not instance member" do
    headers = @admin_headers
    # admin_user is NOT a member of instance :two / project :two
    post "#{MCP_PREFIX}/links",
      params: { project_id: projects(:two).hashid, title: "Hack", path: "hack" },
      headers: headers
    assert_response :forbidden
    json = json_response
    assert_equal "Forbidden", json["error"]
  end

  test "not_found for nonexistent project" do
    headers = @admin_headers
    post "#{MCP_PREFIX}/links",
      params: { project_id: "nonexistent", title: "Ghost", path: "ghost" },
      headers: headers
    assert_response :not_found
    json = json_response
    assert_equal "Project not found", json["error"]
  end

  # ==========================================================================
  # Create Link
  # ==========================================================================

  test "create_link creates a link in the project" do
    headers = @admin_headers
    assert_difference "Link.count", 1 do
      post "#{MCP_PREFIX}/links",
        params: {
          project_id: @project.hashid,
          name: "My MCP Link",
          title: "MCP Link",
          subtitle: "Created via MCP",
          path: "mcp-test-link"
        },
        headers: headers
    end
    assert_response :created
    json = json_response
    assert_equal "My MCP Link", json["link"]["name"]
    assert_equal "MCP Link", json["link"]["title"]
    assert_equal "Created via MCP", json["link"]["subtitle"]
    assert_equal "mcp-test-link", json["link"]["path"]
  end

  test "create_link without project_id returns error" do
    headers = @admin_headers
    assert_no_difference "Link.count" do
      post "#{MCP_PREFIX}/links",
        params: { title: "No Project", path: "no-project" },
        headers: headers
    end
    assert_response :bad_request
  end

  test "create_link with duplicate path returns error" do
    headers = @admin_headers
    assert_no_difference "Link.count" do
      post "#{MCP_PREFIX}/links",
        params: {
          project_id: @project.hashid,
          name: "Duplicate Link",
          title: "Duplicate",
          path: @link.path  # "test-path" already exists in domain :one
        },
        headers: headers
    end
    assert_response :unprocessable_entity
    json = json_response
    assert json["error"].present?, "should return error message for duplicate path"
  end

  test "create_link with tags and data params" do
    headers = @admin_headers
    tags_json = '["promo","summer"]'
    data_json = '[{"key": "offer", "value": "50off"}]'

    assert_difference "Link.count", 1 do
      post "#{MCP_PREFIX}/links",
        params: {
          project_id: @project.hashid,
          name: "Tagged Link",
          title: "Tagged Link",
          path: "tagged-link",
          tags: tags_json,
          data: data_json
        },
        headers: headers
    end
    assert_response :created
    json = json_response
    assert_equal %w[promo summer], json["link"]["tags"]
    assert_equal [{ "key" => "offer", "value" => "50off" }], json["link"]["data"]
  end

  test "create_link with custom redirects" do
    headers = @admin_headers
    assert_difference "Link.count", 1 do
      post "#{MCP_PREFIX}/links",
        params: {
          project_id: @project.hashid,
          name: "Custom Redirect Link",
          title: "Custom Redirect Link",
          path: "custom-redirect-link",
          custom_redirects: {
            ios: { url: "https://apps.apple.com/myapp", open_app_if_installed: true },
            android: { url: "https://play.google.com/myapp", open_app_if_installed: true }
          }
        },
        headers: headers
    end
    assert_response :created
    json = json_response
    assert_equal "custom-redirect-link", json["link"]["path"]

    link = Link.find(json["link"]["id"])
    assert_not_nil link.ios_custom_redirect
    assert_equal "https://apps.apple.com/myapp", link.ios_custom_redirect.url
    assert_equal true, link.ios_custom_redirect.open_app_if_installed
    assert_not_nil link.android_custom_redirect
    assert_equal "https://play.google.com/myapp", link.android_custom_redirect.url
  end

  # The MCP tool schema (server.ts) documents custom_redirects as Record<string, string>,
  # i.e. flat { ios: "url" }. The controller must accept that shape too.
  # Flat format defaults open_app_if_installed=true so iOS/Android still open the
  # installed app when present (then fall back to the custom URL when not).
  # MCP "custom URL only" mode: explicit object form with open_app_if_installed: false
  # disables the app-open attempt, sending users straight to the custom URL.
  test "create_link with custom_redirects open_app_if_installed=false" do
    headers = @admin_headers
    assert_difference "Link.count", 1 do
      post "#{MCP_PREFIX}/links",
        params: {
          project_id: @project.hashid,
          name: "Always Custom URL",
          path: "always-custom-url",
          custom_redirects: {
            ios: { url: "https://example.com/always", open_app_if_installed: false }
          }
        },
        headers: headers
    end
    assert_response :created
    link = Link.find(json_response["link"]["id"])
    assert_equal "https://example.com/always", link.ios_custom_redirect.url
    assert_equal false, link.ios_custom_redirect.open_app_if_installed
  end

  test "create_link accepts flat string custom_redirects (MCP schema format)" do
    headers = @admin_headers
    assert_difference "Link.count", 1 do
      post "#{MCP_PREFIX}/links",
        params: {
          project_id: @project.hashid,
          name: "Flat Redirect Link",
          path: "flat-redirect-link",
          custom_redirects: {
            ios: "https://apps.apple.com/flat",
            android: "https://play.google.com/flat",
            desktop: "https://example.com/flat"
          }
        },
        headers: headers
    end
    assert_response :created
    json = json_response
    link = Link.find(json["link"]["id"])

    assert_not_nil link.ios_custom_redirect
    assert_equal "https://apps.apple.com/flat", link.ios_custom_redirect.url
    assert_equal true, link.ios_custom_redirect.open_app_if_installed
    assert_not_nil link.android_custom_redirect
    assert_equal "https://play.google.com/flat", link.android_custom_redirect.url
    assert_equal true, link.android_custom_redirect.open_app_if_installed
    assert_not_nil link.desktop_custom_redirect
    assert_equal "https://example.com/flat", link.desktop_custom_redirect.url
    # desktop is always false (LinkManagementService passes require_open_app: false)
    assert_equal false, link.desktop_custom_redirect.open_app_if_installed
  end

  test "create_link forbidden for non-member project" do
    headers = @admin_headers
    assert_no_difference "Link.count" do
      post "#{MCP_PREFIX}/links",
        params: { project_id: projects(:two).hashid, title: "Forbidden", path: "forbidden" },
        headers: headers
    end
    assert_response :forbidden
  end

  # ==========================================================================
  # Get Link
  # ==========================================================================

  test "get_link returns link by path with full serializer schema" do
    headers = @admin_headers
    get "#{MCP_PREFIX}/links/by-path/#{@link.path}",
      params: { project_id: @project.hashid },
      headers: headers
    assert_response :ok
    json = json_response
    link_json = json["link"]

    # Core LinkSerializer attributes
    assert_equal @link.id, link_json["id"]
    assert_equal @link.path, link_json["path"]
    assert_equal @link.title, link_json["title"]
    assert_equal @link.name, link_json["name"]
    assert_equal @link.subtitle, link_json["subtitle"]
    assert_equal true, link_json["active"]
    assert_not_nil link_json["updated_at"]

    # Boolean/optional fields present in schema
    assert [true, false, nil].include?(link_json["show_preview_ios"])
    assert [true, false, nil].include?(link_json["show_preview_android"])
    assert [true, false].include?(link_json["sdk_generated"])

    # Non-slim fields present
    assert link_json.key?("access_path"), "should include access_path"
    assert link_json.key?("ios_custom_redirect"), "should include ios_custom_redirect"
    assert link_json.key?("android_custom_redirect"), "should include android_custom_redirect"
    assert link_json.key?("desktop_custom_redirect"), "should include desktop_custom_redirect"
  end

  test "get_link returns 404 for nonexistent path" do
    headers = @admin_headers
    get "#{MCP_PREFIX}/links/by-path/nonexistent-path",
      params: { project_id: @project.hashid },
      headers: headers
    assert_response :not_found
    json = json_response
    assert_equal "Link not found", json["error"]
  end

  test "get_link returns 404 for inactive link" do
    headers = @admin_headers
    get "#{MCP_PREFIX}/links/by-path/#{@inactive_link.path}",
      params: { project_id: @project.hashid },
      headers: headers
    assert_response :not_found
    json = json_response
    assert_equal "Link not found", json["error"]
  end

  # ==========================================================================
  # Update Link
  # ==========================================================================

  test "update_link updates link title using id from serialized response" do
    headers = @admin_headers
    # Get the link id the way a real client would — from a prior API response
    get "#{MCP_PREFIX}/links/by-path/#{@link.path}",
      params: { project_id: @project.hashid },
      headers: headers
    link_id = json_response["link"]["id"]

    patch "#{MCP_PREFIX}/links/#{link_id}",
      params: { project_id: @project.hashid, title: "Updated Title" },
      headers: headers
    assert_response :ok
    json = json_response
    assert_equal "Updated Title", json["link"]["title"]
    assert_equal "Updated Title", @link.reload.title
  end

  test "update_link updates link path" do
    headers = @admin_headers
    patch "#{MCP_PREFIX}/links/#{@link.id}",
      params: { project_id: @project.hashid, path: "new-updated-path" },
      headers: headers
    assert_response :ok
    json = json_response
    assert_equal "new-updated-path", json["link"]["path"]
    assert_equal "new-updated-path", @link.reload.path
  end

  test "update_link updates tags and data" do
    headers = @admin_headers
    patch "#{MCP_PREFIX}/links/#{@link.id}",
      params: {
        project_id: @project.hashid,
        tags: '["updated","tags"]',
        data: '[{"key": "new_key", "value": "new_value"}]'
      },
      headers: headers
    assert_response :ok
    json = json_response
    assert_equal %w[updated tags], json["link"]["tags"]
    assert_equal [{ "key" => "new_key", "value" => "new_value" }], json["link"]["data"]

    @link.reload
    assert_equal %w[updated tags], @link.tags
    assert_equal [{ "key" => "new_key", "value" => "new_value" }], @link.data
  end

  test "update_link updates custom redirects" do
    headers = @admin_headers
    patch "#{MCP_PREFIX}/links/#{@link.id}",
      params: {
        project_id: @project.hashid,
        custom_redirects: {
          ios: { url: "https://apps.apple.com/updated", open_app_if_installed: true },
          android: { url: "https://play.google.com/updated", open_app_if_installed: false }
        }
      },
      headers: headers
    assert_response :ok

    @link.reload
    assert_not_nil @link.ios_custom_redirect
    assert_equal "https://apps.apple.com/updated", @link.ios_custom_redirect.url
    assert_equal true, @link.ios_custom_redirect.open_app_if_installed
    assert_not_nil @link.android_custom_redirect
    assert_equal "https://play.google.com/updated", @link.android_custom_redirect.url
    assert_equal false, @link.android_custom_redirect.open_app_if_installed
  end

  test "update_link accepts flat string custom_redirects (MCP schema format)" do
    headers = @admin_headers
    patch "#{MCP_PREFIX}/links/#{@link.id}",
      params: {
        project_id: @project.hashid,
        custom_redirects: {
          ios: "https://apps.apple.com/flatupd",
          android: "https://play.google.com/flatupd"
        }
      },
      headers: headers
    assert_response :ok

    @link.reload
    assert_not_nil @link.ios_custom_redirect
    assert_equal "https://apps.apple.com/flatupd", @link.ios_custom_redirect.url
    assert_not_nil @link.android_custom_redirect
    assert_equal "https://play.google.com/flatupd", @link.android_custom_redirect.url
  end

  test "update_link returns 404 for nonexistent link id" do
    headers = @admin_headers
    patch "#{MCP_PREFIX}/links/999999999",
      params: { project_id: @project.hashid, title: "Ghost" },
      headers: headers
    assert_response :not_found
    json = json_response
    assert_equal "Link not found", json["error"]
  end

  test "update_link returns 404 for link from another project" do
    headers = @admin_headers
    other_link = links(:second_link) # belongs to domain :two -> project :two
    # admin_user is member of instance :one (project :one), not instance :two
    patch "#{MCP_PREFIX}/links/#{other_link.id}",
      params: { project_id: @project.hashid, title: "Cross Project" },
      headers: headers
    assert_response :not_found
    json = json_response
    assert_equal "Link not found", json["error"]
  end

  # ==========================================================================
  # List Links (Search)
  # ==========================================================================

  test "list_links returns links with aggregated metrics and pagination" do
    headers = @admin_headers
    post "#{MCP_PREFIX}/links/search",
      params: {
        project_id: @project.hashid,
        start_date: "2026-03-01",
        end_date: "2026-03-02"
      },
      headers: headers
    assert_response :ok
    json = json_response

    # Domain :one has 3 active links: basic_link, no_custom_redirect_link, campaign_link
    assert_equal 3, json["links"].length
    paths = json["links"].map { |l| l["path"] }
    assert_includes paths, "test-path"
    assert_includes paths, "standard-path"
    assert_includes paths, "campaign-link-path"

    # basic_link aggregates stat_day1 + stat_day2 from link_daily_statistics.yml
    basic = json["links"].find { |l| l["path"] == "test-path" }
    assert_equal 300, basic["total_views"]           # 100 + 200
    assert_equal 130, basic["total_opens"]            # 50 + 80
    assert_equal 30, basic["total_installs"]          # 10 + 20
    assert_equal 7, basic["total_reinstalls"]         # 2 + 5
    assert_equal 13_000, basic["total_time_spent"]    # 5000 + 8000
    assert_equal 4, basic["total_reactivations"]      # 1 + 3
    assert_equal 10, basic["total_user_referred"]     # 3 + 7
    assert_equal 2998, basic["total_revenue"]         # 999 + 1999

    # no_custom_redirect_link has stat_standard_link_day1 (views:20, installs:2)
    standard = json["links"].find { |l| l["path"] == "standard-path" }
    assert_equal 20, standard["total_views"]
    assert_equal 2, standard["total_installs"]

    # Verify pagination meta
    assert_equal 1, json["meta"]["page"]
    assert_equal 1, json["meta"]["total_pages"]
    assert_equal 3, json["meta"]["total_entries"]
  end

  test "list_links paginates with per_page and page params" do
    headers = @admin_headers
    # Domain :one has 3 active links; per_page: 1 forces 3 pages
    post "#{MCP_PREFIX}/links/search",
      params: {
        project_id: @project.hashid,
        start_date: "2026-03-01",
        end_date: "2026-03-02",
        per_page: 1,
        page: 1
      },
      headers: headers
    assert_response :ok
    page1 = json_response
    assert_equal 1, page1["links"].length
    assert_equal 1, page1["meta"]["page"]
    assert_equal 3, page1["meta"]["total_pages"]
    assert_equal 3, page1["meta"]["total_entries"]
    assert_equal 1, page1["meta"]["per_page"]

    # Request page 2
    post "#{MCP_PREFIX}/links/search",
      params: {
        project_id: @project.hashid,
        start_date: "2026-03-01",
        end_date: "2026-03-02",
        per_page: 1,
        page: 2
      },
      headers: headers
    assert_response :ok
    page2 = json_response
    assert_equal 1, page2["links"].length
    assert_equal 2, page2["meta"]["page"]

    # Pages return different links
    assert_not_equal page1["links"].first["path"], page2["links"].first["path"]
  end

  test "list_links requires project_id" do
    headers = @admin_headers
    post "#{MCP_PREFIX}/links/search",
      params: {},
      headers: headers
    assert_response :bad_request
  end

  test "list_links forbidden for non-member" do
    headers = @admin_headers
    post "#{MCP_PREFIX}/links/search",
      params: { project_id: projects(:two).hashid },
      headers: headers
    assert_response :forbidden
  end

  # ==========================================================================
  # Archive Link
  # ==========================================================================

  test "archive_link deactivates the link and returns full schema" do
    assert @link.active, "link should start active"

    delete "#{MCP_PREFIX}/links/#{@link.id}",
      params: { project_id: @project.hashid },
      headers: @admin_headers
    assert_response :ok
    l = json_response["link"]

    assert_equal @link.id, l["id"]
    assert_equal false, l["active"]
    assert_not_nil l["name"]
    assert_not_nil l["path"]

    @link.reload
    assert_not @link.active, "link must be deactivated in DB"
  end

  test "archive_link returns 404 for nonexistent link" do
    delete "#{MCP_PREFIX}/links/999999999",
      params: { project_id: @project.hashid },
      headers: @admin_headers
    assert_response :not_found
    assert_equal "Link not found", json_response["error"]
  end

  test "archive_link returns 404 for link from wrong project" do
    other_link = links(:second_link)
    delete "#{MCP_PREFIX}/links/#{other_link.id}",
      params: { project_id: @project.hashid },
      headers: @admin_headers
    assert_response :not_found
  end

  # ==========================================================================
  # Member User Access
  # ==========================================================================

  test "member_user can create links" do
    assert_difference "Link.count", 1 do
      post "#{MCP_PREFIX}/links",
        params: { project_id: @project.hashid, name: "Member Link", title: "Member Link", path: "member-created-link" },
        headers: @member_headers
    end
    assert_response :created
  end

  test "member_user can get links" do
    get "#{MCP_PREFIX}/links/by-path/#{@link.path}",
      params: { project_id: @project.hashid },
      headers: @member_headers
    assert_response :ok
  end

  # ==========================================================================
  # Quota Warning
  # ==========================================================================

  test "response includes _warning when quota_exceeded is true" do
    @instance.update_column(:quota_exceeded, true)

    post "#{MCP_PREFIX}/links",
      params: {
        project_id: @project.hashid,
        name: "Quota Link",
        title: "Quota Link",
        path: "quota-warning-link"
      },
      headers: @admin_headers
    assert_response :created
    json = json_response
    assert json["_warning"].present?, "response should include _warning when quota exceeded"
    assert_includes json["_warning"], "exceeded the free tier limit"
  end

  test "response does not include _warning when quota_exceeded is false" do
    @instance.update_column(:quota_exceeded, false)

    post "#{MCP_PREFIX}/links",
      params: {
        project_id: @project.hashid,
        name: "Normal Link",
        title: "Normal Link",
        path: "no-warning-link"
      },
      headers: @admin_headers
    assert_response :created
    json = json_response
    assert_nil json["_warning"], "response should not include _warning when quota is fine"
  end

  test "member_user cannot access projects they do not belong to" do
    post "#{MCP_PREFIX}/links",
      params: { project_id: projects(:two).hashid, title: "Nope", path: "nope" },
      headers: @member_headers
    assert_response :forbidden
  end

  test "member_user can access list_links" do
    post "#{MCP_PREFIX}/links/search",
      params: { project_id: @project.hashid, start_date: "2026-03-01", end_date: "2026-03-02" },
      headers: @member_headers
    assert_response :ok
  end
end
