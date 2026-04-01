require "test_helper"
require_relative "auth_test_helper"

class DomainsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @project_two = projects(:two)
    @domain = domains(:one)
    @headers = doorkeeper_headers_for(@admin_user)
  end

  # --- Unauthenticated ---

  test "get domain without auth returns 401 with no data" do
    get "#{API_PREFIX}/projects/#{@project.id}/domain", headers: api_headers
    assert_response :unauthorized
    assert_no_match(/"domain"/, response.body, "401 must not leak domain data")
  end

  # --- Get Domain ---

  test "get current project domain returns correct serialized data" do
    get "#{API_PREFIX}/projects/#{@project.id}/domain", headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    domain_data = json["domain"]
    assert_equal @domain.subdomain, domain_data["subdomain"]
    assert_equal @domain.domain, domain_data["domain"]
    assert domain_data.key?("generic_title"), "must include generic_title"
    assert domain_data.key?("google_tracking_id"), "must include google_tracking_id"
  end

  # --- Update Domain ---

  test "update domain persists generic_title and subtitle in DB" do
    put "#{API_PREFIX}/projects/#{@project.id}/domain",
      params: { generic_title: "Updated Title", generic_subtitle: "Updated Sub" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "Updated Title", json["domain"]["generic_title"]
    assert_equal "Updated Sub", json["domain"]["generic_subtitle"]

    @domain.reload
    assert_equal "Updated Title", @domain.generic_title, "title must persist in DB"
    assert_equal "Updated Sub", @domain.generic_subtitle, "subtitle must persist in DB"
  end

  # --- Check Subdomain Availability ---

  test "check subdomain availability for unused subdomain returns true" do
    post "#{API_PREFIX}/projects/#{@project.id}/domain/check_availability",
      params: { subdomain: "totally-unique-subdomain-xyz" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal true, json["available"]
  end

  test "check subdomain availability for taken subdomain returns false" do
    post "#{API_PREFIX}/projects/#{@project.id}/domain/check_availability",
      params: { subdomain: @domain.subdomain },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal false, json["available"]
  end

  # --- Set Google Tracking ID ---

  test "set google tracking ID persists in DB and returns in response" do
    put "#{API_PREFIX}/projects/#{@project.id}/domain/google_tracking_id",
      params: { google_tracking_id: "UA-12345678-1" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "UA-12345678-1", json["domain"]["google_tracking_id"]

    @domain.reload
    assert_equal "UA-12345678-1", @domain.google_tracking_id, "tracking ID must persist in DB"
  end

  # --- Domain Defaults ---

  test "get domain defaults returns env-configured placeholder values" do
    get "#{API_PREFIX}/projects/#{@project.id}/domain/defaults", headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)

    assert_equal Grovs::Links::DEFAULT_TITLE, json["generic_title"]
    assert_equal Grovs::Links::DEFAULT_SUBTITLE, json["generic_subtitle"]
    assert_equal Grovs::Links::SOCIAL_PREVIEW, json["generic_image_url"]
  end

  test "get domain defaults returns exactly three keys" do
    get "#{API_PREFIX}/projects/#{@project.id}/domain/defaults", headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)

    assert_equal %w[generic_image_url generic_subtitle generic_title], json.keys.sort
  end

  test "get domain defaults without auth returns 401" do
    get "#{API_PREFIX}/projects/#{@project.id}/domain/defaults", headers: api_headers
    assert_response :unauthorized
  end

  test "domain defaults match LinkDisplayService fallback values" do
    get "#{API_PREFIX}/projects/#{@project.id}/domain/defaults", headers: @headers
    json = JSON.parse(response.body)

    # Build a link with no title/subtitle/image to trigger LinkDisplayService defaults
    link_data = LinkDisplayService.generic_data_for_link(
      OpenStruct.new(
        title: nil, subtitle: nil, image_resource: nil,
        access_path: "/test", tracking_campaign: nil, tracking_source: nil, tracking_medium: nil,
        domain: OpenStruct.new(generic_title: nil, generic_subtitle: nil, image_url: nil, full_domain: "test.sqd.link")
      )
    )

    assert_equal link_data[:page_title], json["generic_title"],
      "Defaults endpoint title must match LinkDisplayService fallback"
    assert_equal link_data[:page_subtitle], json["generic_subtitle"],
      "Defaults endpoint subtitle must match LinkDisplayService fallback"
    assert_equal link_data[:page_image], json["generic_image_url"],
      "Defaults endpoint image must match LinkDisplayService fallback"
  end

  test "get domain defaults for another instance project returns 403" do
    get "#{API_PREFIX}/projects/#{@project_two.id}/domain/defaults", headers: @headers
    assert_response :forbidden
  end

  # --- Cross-Tenant ---

  test "access another instance project domain returns 403 with no data leak" do
    get "#{API_PREFIX}/projects/#{@project_two.id}/domain", headers: @headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Forbidden", json["error"]
    assert_not json.key?("domain"), "403 must not leak domain data"
  end
end
