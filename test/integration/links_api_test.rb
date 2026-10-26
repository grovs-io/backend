require "test_helper"
require_relative "auth_test_helper"

class LinksApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :links, :campaigns

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @project_two = projects(:two)
    @link = links(:basic_link)
    @headers = doorkeeper_headers_for(@admin_user)
  end

  # --- Unauthenticated ---

  test "create link without auth returns 401 with no data" do
    post "#{API_PREFIX}/projects/#{@project.id}/links",
      params: { title: "Test", path: "new-link" },
      headers: api_headers
    assert_response :unauthorized
    assert_no_match(/"link"/, response.body, "401 must not contain link data")
  end

  # --- Create Link ---

  test "create link persists to DB and returns correct data" do
    assert_difference "Link.count", 1 do
      post "#{API_PREFIX}/projects/#{@project.id}/links",
        params: { title: "New Link", subtitle: "Test subtitle", path: "new-integration-link" },
        headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "New Link", json["link"]["title"]
    assert_equal "Test subtitle", json["link"]["subtitle"]
    assert_equal "new-integration-link", json["link"]["path"]

    created = Link.find_by(path: "new-integration-link")
    assert_not_nil created
    assert created.active, "new link must be active"
    assert_equal "dashboard", created.generated_from_platform
  end

  test "create link with invalid campaign_id returns error" do
    assert_no_difference "Link.count" do
      post "#{API_PREFIX}/projects/#{@project.id}/links",
        params: { title: "Test Link", path: "fail-link", campaign_id: "not_an_integer" },
        headers: @headers
    end
    assert_response :bad_request
  end

  # --- Search Links ---

  test "search links returns paginated results with fixture link" do
    post "#{API_PREFIX}/projects/#{@project.id}/links/search",
      params: { active: "true", sdk: "false", start_date: "2026-01-01" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["data"], "must return data array"
    assert json.key?("total_entries"), "must include total_entries for pagination"
    assert json.key?("page"), "must include page for pagination"

    paths = json["data"].map { |l| l["path"] }
    assert_includes paths, @link.path, "fixture link must appear in search results"
  end

  # --- Search Links v2 ---

  test "search_v2 filters by ads_platform with the dashboard body shape" do
    @link.update!(ads_platform: "google")

    body = {
      active: true, sdk: false, ascending: false, page: 1, per_page: 25,
      start_date: "2026-01-01T00:00:00.000Z", sort_by: "updated_at",
      ads_platform: "google"
    }
    post "#{API_PREFIX}/projects/#{@project.id}/links/search_v2",
      params: body, headers: @headers, as: :json
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal [@link.id], json["links"].map { |l| l["id"] }

    post "#{API_PREFIX}/projects/#{@project.id}/links/search_v2",
      params: body.merge(ads_platform: "meta"), headers: @headers, as: :json
    assert_response :ok
    assert_equal [], JSON.parse(response.body)["links"]
  end

  test "search_v2 honors ascending sort direction" do
    body = { active: true, sdk: false, page: 1, per_page: 25,
             start_date: "2026-01-01T00:00:00.000Z", sort_by: "created_at" }

    # basic_link (created 2026-03-01) is the oldest active link in the project
    post "#{API_PREFIX}/projects/#{@project.id}/links/search_v2",
      params: body.merge(ascending: true), headers: @headers, as: :json
    assert_response :ok
    assert_equal @link.id, JSON.parse(response.body)["links"].first["id"]

    post "#{API_PREFIX}/projects/#{@project.id}/links/search_v2",
      params: body.merge(ascending: false), headers: @headers, as: :json
    assert_response :ok
    assert_equal @link.id, JSON.parse(response.body)["links"].last["id"]
  end

  # --- Check Path Availability ---

  test "check path for unused path returns true" do
    post "#{API_PREFIX}/projects/#{@project.id}/links/check_path",
      params: { path: "completely-unique-path-xyz" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal true, json["available"]
  end

  test "check path for existing path returns false" do
    post "#{API_PREFIX}/projects/#{@project.id}/links/check_path",
      params: { path: @link.path },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal false, json["available"]
  end

  # --- Generate Random Path ---

  test "generate random path returns a unique non-empty string" do
    get "#{API_PREFIX}/projects/#{@project.id}/links/random_path",
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    path = json["valid_path"]
    assert_kind_of String, path, "path must be a string"
    assert path.length >= 4, "path must have reasonable length (>= 4 chars)"
    assert_nil Link.find_by(path: path), "generated path must not collide with existing links"
  end

  # --- Update Link ---

  test "update link sets copy_to_clipboard toggles" do
    patch "#{API_PREFIX}/projects/#{@project.id}/links/#{@link.id}",
      params: { copy_to_clipboard_ios: true },
      headers: @headers
    assert_response :ok

    @link.reload
    assert_equal true, @link.copy_to_clipboard_ios
    assert_nil @link.copy_to_clipboard_android
  end

  test "update link persists change and returns updated data" do
    patch "#{API_PREFIX}/projects/#{@project.id}/links/#{@link.id}",
      params: { title: "Updated Title" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "Updated Title", json["link"]["title"]

    @link.reload
    assert_equal "Updated Title", @link.title, "title must be persisted in DB"
  end

  # --- Delete Link ---

  test "delete link archives it" do
    delete "#{API_PREFIX}/projects/#{@project.id}/links/#{@link.id}",
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "Link deleted!", json["message"]

    @link.reload
    assert_not @link.active, "link must be deactivated after delete"
  end

  # --- Nonexistent Resource ---

  test "update nonexistent link returns 404 with no data leak" do
    patch "#{API_PREFIX}/projects/#{@project.id}/links/999999999",
      params: { title: "Ghost" },
      headers: @headers
    assert_response :not_found
    json = JSON.parse(response.body)
    assert json.key?("error"), "404 must include error message"
    assert_no_match(/Ghost/, response.body, "404 must not echo submitted data")
  end

  test "delete nonexistent link returns 404 with no data leak" do
    delete "#{API_PREFIX}/projects/#{@project.id}/links/999999999",
      headers: @headers
    assert_response :not_found
    json = JSON.parse(response.body)
    assert json.key?("error"), "404 must include error message"
    assert_no_match(/"link"/, response.body, "404 must not leak link data")
  end

  # --- Smart banner links are system-owned ---

  test "update a smart banner link returns 422 and does not change it" do
    @link.update_column(:tags, ["smart_banner", "smart_banner:1"])

    patch "#{API_PREFIX}/projects/#{@project.id}/links/#{@link.id}",
      params: { title: "Hacked" },
      headers: @headers
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json.key?("error")

    assert_not_equal "Hacked", @link.reload.title
  end

  test "delete a smart banner link returns 422 and does not archive it" do
    @link.update_column(:tags, ["smart_banner", "smart_banner:1"])

    delete "#{API_PREFIX}/projects/#{@project.id}/links/#{@link.id}",
      headers: @headers
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json.key?("error")

    assert @link.reload.active
  end

  # --- Duplicate Path ---

  test "create link with existing path returns 422" do
    assert_no_difference "Link.count" do
      post "#{API_PREFIX}/projects/#{@project.id}/links",
        params: { title: "Duplicate", path: @link.path },
        headers: @headers
    end
    assert_response :unprocessable_entity
    assert_equal({ "error" => "Validation failed: Path There's an existing link for this domain and path" }, JSON.parse(response.body))
  end

  test "create link without a path returns 422 and creates nothing" do
    [{ title: "No path" }, { title: "Blank path", path: "  " }].each do |params|
      assert_no_difference "Link.count" do
        post "#{API_PREFIX}/projects/#{@project.id}/links", params: params, headers: @headers
      end
      assert_response :unprocessable_entity
      assert_equal({ "error" => "Validation failed: Path can't be blank" }, JSON.parse(response.body))
    end
  end

  # --- Path Availability Edge Cases ---

  test "check path with special characters returns unavailable" do
    post "#{API_PREFIX}/projects/#{@project.id}/links/check_path",
      params: { path: "bad path!@#" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal false, json["available"], "path with special characters must be unavailable"
  end

  # --- Empty Search Results ---

  test "search with sdk true returns empty array when no SDK links exist" do
    post "#{API_PREFIX}/projects/#{@project.id}/links/search",
      params: { active: "true", sdk: "true" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["data"], "must return data array"
    assert_equal 0, json["data"].size, "no SDK links in fixtures"
    assert json.key?("total_entries"), "must include pagination meta"
    assert json.key?("page"), "must include page meta"
  end

  # --- Create with Campaign ---

  test "create link with valid campaign_id associates link to campaign" do
    campaign = campaigns(:one)
    assert_difference "Link.count", 1 do
      post "#{API_PREFIX}/projects/#{@project.id}/links",
        params: { title: "Campaign Link", path: "new-campaign-link-path", campaign_id: campaign.id },
        headers: @headers
    end
    assert_response :ok
    created = Link.find_by(path: "new-campaign-link-path")
    assert_not_nil created
    assert_equal campaign.id, created.campaign_id, "link must be associated to campaign"
  end

  test "lookup returns links older than the retention window used by search_v2" do
    assert @link.created_at < 30.days.ago, "fixture must predate the default 30-day window"

    get "#{API_PREFIX}/projects/#{@project.id}/links/lookup", headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_includes json["links"].map { |l| l["id"] }, @link.id
  end

  test "lookup term filters by name and path case-insensitively" do
    get "#{API_PREFIX}/projects/#{@project.id}/links/lookup", params: { term: "spring campaign" }, headers: @headers
    assert_response :ok
    ids = JSON.parse(response.body)["links"].map { |l| l["id"] }
    assert_includes ids, @link.id

    get "#{API_PREFIX}/projects/#{@project.id}/links/lookup", params: { term: "TEST-PATH" }, headers: @headers
    assert_response :ok
    ids = JSON.parse(response.body)["links"].map { |l| l["id"] }
    assert_includes ids, @link.id
  end

  test "lookup treats % and _ in term as literal characters" do
    domain = domains(:one)
    redirect_config = redirect_configs(:one)
    percent_link = Link.create!(domain: domain, redirect_config: redirect_config, path: "percent-link",
                                 title: "50% off deal", generated_from_platform: "ios", active: true, sdk_generated: false)
    lookalike_link = Link.create!(domain: domain, redirect_config: redirect_config, path: "lookalike-link",
                                   title: "50xoffdeal", generated_from_platform: "ios", active: true, sdk_generated: false)
    underscore_link = Link.create!(domain: domain, redirect_config: redirect_config, path: "ab_cd-underscore",
                                    generated_from_platform: "ios", active: true, sdk_generated: false)
    wildcard_lookalike = Link.create!(domain: domain, redirect_config: redirect_config, path: "abXcd-underscore",
                                       generated_from_platform: "ios", active: true, sdk_generated: false)

    get "#{API_PREFIX}/projects/#{@project.id}/links/lookup", params: { term: "50%" }, headers: @headers
    ids = JSON.parse(response.body)["links"].map { |l| l["id"] }
    assert_includes ids, percent_link.id
    assert_not_includes ids, lookalike_link.id

    get "#{API_PREFIX}/projects/#{@project.id}/links/lookup", params: { term: "ab_cd" }, headers: @headers
    ids = JSON.parse(response.body)["links"].map { |l| l["id"] }
    assert_includes ids, underscore_link.id
    assert_not_includes ids, wildcard_lookalike.id
  end

  test "lookup excludes inactive links, sdk_generated links, and links from another project" do
    domain = domains(:one)
    redirect_config = redirect_configs(:one)
    sdk_link = Link.create!(domain: domain, redirect_config: redirect_config, path: "sdk-lookup-path",
                             generated_from_platform: "ios", active: true, sdk_generated: true)

    get "#{API_PREFIX}/projects/#{@project.id}/links/lookup", headers: @headers
    assert_response :ok
    ids = JSON.parse(response.body)["links"].map { |l| l["id"] }
    assert_not_includes ids, links(:inactive_link).id
    assert_not_includes ids, sdk_link.id
    assert_not_includes ids, links(:second_link).id, "must not leak links from another project's domain"
  end

  test "lookup limit defaults to 20 and clamps requested value" do
    get "#{API_PREFIX}/projects/#{@project.id}/links/lookup", params: { limit: 1 }, headers: @headers
    assert_response :ok
    assert_equal 1, JSON.parse(response.body)["links"].size

    domain = domains(:one)
    redirect_config = redirect_configs(:one)
    25.times do |i|
      Link.create!(domain: domain, redirect_config: redirect_config, path: "lookup-limit-#{i}",
                   generated_from_platform: "ios", active: true, sdk_generated: false)
    end

    get "#{API_PREFIX}/projects/#{@project.id}/links/lookup", headers: @headers
    assert_response :ok
    assert_equal 20, JSON.parse(response.body)["links"].size
  end

  test "lookup answers 404, not 204, when the project has no domain" do
    domains(:one).destroy!
    get "#{API_PREFIX}/projects/#{@project.id}/links/lookup", headers: @headers
    assert_response :not_found
    assert_equal "Domain not found", JSON.parse(response.body)["error"]
  end

  test "lookup without auth returns 401 with no data" do
    get "#{API_PREFIX}/projects/#{@project.id}/links/lookup", headers: api_headers
    assert_response :unauthorized
    assert_no_match(/"links"/, response.body, "401 must not contain link data")
  end

  test "lookup for a non-member instance returns 403 with no data leak" do
    get "#{API_PREFIX}/projects/#{@project_two.id}/links/lookup", headers: @headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Forbidden", json["error"]
    assert_not json.key?("links"), "403 must not leak link data from other tenant"
  end

  test "lookup allows a non-admin project member to read" do
    member_headers = doorkeeper_headers_for(users(:member_user))
    get "#{API_PREFIX}/projects/#{@project.id}/links/lookup", headers: member_headers
    assert_response :ok
  end

  # --- Cross-Tenant Access ---

  test "access another instance project returns 403 with no data leak" do
    post "#{API_PREFIX}/projects/#{@project_two.id}/links/search",
      params: { active: "true", sdk: "false" },
      headers: @headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Forbidden", json["error"]
    assert_not json.key?("data"), "403 must not leak link data from other tenant"
  end
end
