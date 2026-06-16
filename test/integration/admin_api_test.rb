require "test_helper"
require_relative "auth_test_helper"

class AdminApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects

  ADMIN_KEY = "test-admin-secret-key-12345"

  setup do
    @instance = instances(:one)
  end

  # --- Authentication ---

  test "request without X-AUTH header returns 403" do
    with_admin_key(ADMIN_KEY) do
      post "#{API_PREFIX}/admin/create_enterprise_subscription",
        params: { instance_id: @instance.id },
        headers: api_headers
      assert_response :forbidden
      json = JSON.parse(response.body)
      assert_equal "Invalid credentials", json["error"]
    end
  end

  test "request with wrong X-AUTH header returns 403" do
    with_admin_key(ADMIN_KEY) do
      post "#{API_PREFIX}/admin/create_enterprise_subscription",
        params: { instance_id: @instance.id },
        headers: api_headers.merge("X-AUTH" => "wrong-key")
      assert_response :forbidden
    end
  end

  test "request when ADMIN_API_KEY env is blank returns 403" do
    with_admin_key("") do
      post "#{API_PREFIX}/admin/create_enterprise_subscription",
        params: { instance_id: @instance.id },
        headers: api_headers.merge("X-AUTH" => "anything")
      assert_response :forbidden
    end
  end

  # --- create_enterprise_subscription ---

  test "create_enterprise_subscription with valid key creates record" do
    with_admin_key(ADMIN_KEY) do
      assert_difference "EnterpriseSubscription.count", 1 do
        post "#{API_PREFIX}/admin/create_enterprise_subscription",
          params: {
            instance_id: @instance.id,
            start_date: "2026-01-01",
            end_date: "2026-12-31",
            total_maus: 50_000,
            active: true
          },
          headers: admin_headers
        assert_response :created
      end
      json = JSON.parse(response.body)
      assert_equal "Enterprise Subscription created successfully", json["message"]
    end
  end

  test "create_enterprise_subscription with missing fields returns 422" do
    with_admin_key(ADMIN_KEY) do
      post "#{API_PREFIX}/admin/create_enterprise_subscription",
        params: { instance_id: @instance.id },
        headers: admin_headers
      assert_response :unprocessable_entity
      json = JSON.parse(response.body)
      assert json["error"].include?("Missing required fields")
    end
  end

  test "create_enterprise_subscription for nonexistent instance returns 404" do
    with_admin_key(ADMIN_KEY) do
      post "#{API_PREFIX}/admin/create_enterprise_subscription",
        params: {
          instance_id: 999_999,
          start_date: "2026-01-01",
          end_date: "2026-12-31",
          total_maus: 10_000,
          active: true
        },
        headers: admin_headers
      assert_response :not_found
    end
  end

  # --- update_enterprise_subscription ---

  test "update_enterprise_subscription with valid key updates record" do
    with_admin_key(ADMIN_KEY) do
      es = EnterpriseSubscription.create!(
        instance: @instance, active: true, total_maus: 10_000,
        start_date: "2026-01-01", end_date: "2026-06-30"
      )

      patch "#{API_PREFIX}/admin/update_enterprise_subscription",
        params: { id: es.id, total_maus: 100_000 },
        headers: admin_headers
      assert_response :ok
      assert_equal 100_000, es.reload.total_maus
    end
  end

  # --- flush_events ---

  test "flush_events with valid key returns 200" do
    with_admin_key(ADMIN_KEY) do
      stub_result = { processed: 42, discarded: 3, dates_aggregated: ["2026-03-19"] }
      EventFlushService.stub(:flush, stub_result) do
        post "#{API_PREFIX}/admin/flush_events",
          params: { aggregate_days: 1 },
          headers: admin_headers
        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 42, json["processed"]
      end
    end
  end

  private

  def admin_headers
    api_headers.merge("X-AUTH" => ADMIN_KEY)
  end

  def with_admin_key(key)
    original = ENV["ADMIN_API_KEY"]
    ENV["ADMIN_API_KEY"] = key
    yield
  ensure
    ENV["ADMIN_API_KEY"] = original
  end
end

class AdminFirebaseMigrationTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects, :domains, :redirect_configs

  ADMIN_KEY = "test-admin-secret-key-12345"

  setup do
    @project = projects(:one)
  end

  def with_admin_key(key)
    original = ENV["ADMIN_API_KEY"]
    ENV["ADMIN_API_KEY"] = key
    yield
  ensure
    ENV["ADMIN_API_KEY"] = original
  end

  def csv_upload(content)
    file = Tempfile.new(["firebase", ".csv"])
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/csv")
  end

  test "migrate_firebase_links imports rows and reports skips" do
    csv = <<~CSV
      name,short_link,link,utm_campaign,utm_medium,utm_source
      Promo,https://fb.gl/promo1,https://fb.page.link/app/home,spring,email,newsletter
      Blank,,https://fb.page.link/app/x,,,
    CSV

    with_admin_key(ADMIN_KEY) do
      assert_difference "Link.count", 1 do
        post "#{API_PREFIX}/admin/migrate_firebase_links",
          params: { project_id: @project.id, file: csv_upload(csv),
                    short_link_prefix: "https://fb.gl/" },
          headers: api_headers.merge("X-AUTH" => ADMIN_KEY)
      end
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 1, json["created_count"]
    assert_equal 1, json["skipped_count"]
    assert_equal "blank_path", json["skipped"][0]["reason"]

    link = Link.find_by(domain: @project.domain, path: "promo1")
    assert_equal "Promo", link.name
    assert_equal "spring", link.tracking_campaign
    data = link.data.is_a?(Array) ? link.data[0] : link.data
    assert_equal "https://fb.page.link/app/home", data["appLink"]
  end

  test "duplicate paths are skipped, not overwritten" do
    Link.create!(name: "existing", path: "promo1", domain: @project.domain,
                 generated_from_platform: "dashboard", active: true,
                 redirect_config: @project.redirect_config)
    csv = "name,short_link,link\nPromo,https://fb.gl/promo1,https://fb.page.link/x\n"

    with_admin_key(ADMIN_KEY) do
      assert_no_difference "Link.count" do
        post "#{API_PREFIX}/admin/migrate_firebase_links",
          params: { project_id: @project.id, file: csv_upload(csv),
                    short_link_prefix: "https://fb.gl/" },
          headers: api_headers.merge("X-AUTH" => ADMIN_KEY)
      end
    end

    assert_response :ok
    assert_equal "duplicate_on_domain", JSON.parse(response.body)["skipped"][0]["reason"]
  end

  test "non-csv upload returns 422" do
    file = Tempfile.new(["bad", ".txt"])
    file.write("not a csv")
    file.rewind

    with_admin_key(ADMIN_KEY) do
      post "#{API_PREFIX}/admin/migrate_firebase_links",
        params: { project_id: @project.id,
                  file: Rack::Test::UploadedFile.new(file.path, "text/plain") },
        headers: api_headers.merge("X-AUTH" => ADMIN_KEY)
    end

    assert_response :unprocessable_entity
  end

  test "unknown project returns 404" do
    with_admin_key(ADMIN_KEY) do
      post "#{API_PREFIX}/admin/migrate_firebase_links",
        params: { project_id: 0, file: csv_upload("name,short_link,link\n") },
        headers: api_headers.merge("X-AUTH" => ADMIN_KEY)
    end

    assert_response :not_found
  end
end
