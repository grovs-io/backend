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
      params: { active: "true", sdk: "false" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["data"], "must return data array"
    assert json.key?("total_entries"), "must include total_entries for pagination"
    assert json.key?("page"), "must include page for pagination"

    paths = json["data"].map { |l| l["path"] }
    assert_includes paths, @link.path, "fixture link must appear in search results"
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

  # --- Duplicate Path ---

  test "create link with existing path returns 422" do
    assert_no_difference "Link.count" do
      post "#{API_PREFIX}/projects/#{@project.id}/links",
        params: { title: "Duplicate", path: @link.path },
        headers: @headers
    end
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json.key?("error"), "422 must include error message"
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
        params: { title: "Campaign Link", path: "campaign-link-path", campaign_id: campaign.id },
        headers: @headers
    end
    assert_response :ok
    created = Link.find_by(path: "campaign-link-path")
    assert_not_nil created
    assert_equal campaign.id, created.campaign_id, "link must be associated to campaign"
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
