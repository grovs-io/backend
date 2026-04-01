require "test_helper"

class QuickLinksTest < ActionDispatch::IntegrationTest
  fixtures :instances, :projects, :domains, :quick_links

  setup do
    @quick_link = quick_links(:basic_quick_link)
    # PublicLinkController#domain looks for Domain(domain: LIVE, subdomain: GO)
    @go_domain = Domain.find_or_create_by!(
      domain: Grovs::Domains::LIVE,
      subdomain: Grovs::Subdomains::GO,
      project: projects(:one)
    )
    @host = "go.sqd.link"
  end

  # --- get_link ---

  test "get_link with valid path renders quick_link template" do
    get "/#{@quick_link.path}", headers: { "Host" => @host }
    assert_response :ok
    assert_includes response.body, @quick_link.title
  end

  test "get_link sets page_title from link title" do
    get "/#{@quick_link.path}", headers: { "Host" => @host }
    assert_response :ok
    assert_includes response.body, @quick_link.title
  end

  test "get_link with missing path renders not_found" do
    get "/nonexistent-path-xyz", headers: { "Host" => @host }
    assert_response :ok
    assert_includes response.body, "Lost in the Void"
  end

  # --- create ---

  test "create with valid params creates QuickLink and returns JSON" do
    assert_difference "QuickLink.count", 1 do
      post "/create", params: {
        title: "New Quick Link",
        subtitle: "A new link",
        ios_phone: "https://apps.apple.com/app/id456",
        android_phone: "https://play.google.com/store/apps/details?id=com.new"
      }, headers: { "Host" => @host }
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert json["link"].present?
    assert json["link"]["path"].present?
    assert_equal "New Quick Link", json["link"]["title"]
    assert_equal "A new link", json["link"]["subtitle"]
  end

  test "create generates a 5-character path" do
    post "/create", params: {
      title: "Path Test",
      ios_phone: "https://apps.apple.com/app/id789"
    }, headers: { "Host" => @host }

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 5, json["link"]["path"].length
  end

  test "create returns access_path in response" do
    post "/create", params: {
      title: "Access Path Test"
    }, headers: { "Host" => @host }

    assert_response :ok
    json = JSON.parse(response.body)
    assert json["link"]["access_path"].present?
    assert json["link"]["access_path"].start_with?("https://")
  end

  test "create assigns go domain to the quick link" do
    post "/create", params: { title: "Domain Test" },
      headers: { "Host" => @host }

    assert_response :ok
    json = JSON.parse(response.body)
    created_link = QuickLink.find_by(path: json["link"]["path"])
    assert_equal @go_domain.id, created_link.domain_id
  end

  # --- generate_random_path logic bug (masked by path length) ---
  #
  # The method has a logic error on line 59:
  #   `break path unless QuickLink.exists?(path: path) && path != "create"`
  # Should be `||` not `&&`. With `&&`, if path == "create", the second operand
  # is false, so `unless false` → breaks and returns "create" as the path.
  #
  # HOWEVER: SecureRandom.hex(32)[0, 5] always produces a 5-char hex string (0-9, a-f),
  # and "create" is 6 characters. So path can NEVER equal "create" — the bug is
  # unreachable. It's still wrong logic that should be fixed (if the path length
  # ever changes, the bug becomes exploitable and "create" would conflict with
  # POST /create route).

  test "generated paths are always 5 hex characters (which prevents the create collision bug)" do
    5.times do |i|
      post "/create", params: { title: "Hex check #{i}" },
        headers: { "Host" => @host }
      assert_response :ok
      json = JSON.parse(response.body)
      path = json["link"]["path"]
      assert_equal 5, path.length, "Path should be exactly 5 characters"
      assert_match(/\A[0-9a-f]{5}\z/, path, "Path should be hex-only characters")
      assert_not_equal "create", path
    end
  end

  test "create generates unique paths for multiple links" do
    paths = []
    3.times do |i|
      post "/create", params: { title: "Unique Test #{i}" },
        headers: { "Host" => @host }
      assert_response :ok
      json = JSON.parse(response.body)
      paths << json["link"]["path"]
    end

    assert_equal paths.uniq.length, paths.length,
      "All generated paths should be unique"
  end

  # --- CSRF ---

  test "CSRF token is not required for create" do
    post "/create", params: { title: "No CSRF" },
      headers: { "Host" => @host }
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "No CSRF", json["link"]["title"]
  end
end
