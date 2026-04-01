require "test_helper"
require_relative "auth_test_helper"
require "sidekiq/testing"

class ExportApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @project_two = projects(:two)
    @instance = instances(:one)
    @headers = doorkeeper_headers_for(@admin_user)
  end

  # --- Unauthenticated ---

  test "export link data without auth returns 401 with no data" do
    post "#{API_PREFIX}/projects/#{@project.id}/exports/links", headers: api_headers
    assert_response :unauthorized
    assert_no_match(/"message"/, response.body, "401 must not leak export status")
  end

  # --- Export Link Data ---

  test "export link data enqueues ExportLinkDataJob and returns 202" do
    Sidekiq::Testing.fake! do
      ExportLinkDataJob.jobs.clear

      post "#{API_PREFIX}/projects/#{@project.id}/exports/links",
        params: { active: true, sdk: false },
        headers: @headers
      assert_response :accepted
      json = JSON.parse(response.body)
      assert_equal "Export job has been queued. You will be notified when it's ready.", json["message"]

      # Verify the Sidekiq job was actually enqueued
      assert_equal 1, ExportLinkDataJob.jobs.size, "must enqueue exactly 1 ExportLinkDataJob"

      job = ExportLinkDataJob.jobs.first
      assert_equal @project.id, job["args"][0], "job must receive project_id"
      assert_equal @admin_user.id, job["args"][2], "job must receive current_user_id"

      # Verify safe_params are passed correctly
      safe_params = job["args"][1]
      assert_equal true, safe_params["active"], "active param must be true"
      assert_equal false, safe_params["sdk"], "sdk param must be false"
    end
  end

  # --- Export Usage Data ---

  test "export usage data enqueues ExportActivityDataJob and returns 202" do
    Sidekiq::Testing.fake! do
      ExportActivityDataJob.jobs.clear

      post "#{API_PREFIX}/instances/#{@instance.id}/exports/usage",
        params: { start_date: "2026-03-01", end_date: "2026-03-31" },
        headers: @headers
      assert_response :accepted
      json = JSON.parse(response.body)
      assert_equal "Export job has been queued. You will be notified when it's ready.", json["message"]

      # Verify the Sidekiq job was actually enqueued
      assert_equal 1, ExportActivityDataJob.jobs.size, "must enqueue exactly 1 ExportActivityDataJob"

      job = ExportActivityDataJob.jobs.first
      assert_equal @instance.id, job["args"][0], "job must receive instance_id"
      assert_equal @admin_user.id, job["args"][2], "job must receive current_user_id"

      safe_params = job["args"][1]
      assert_equal "2026-03-01", safe_params["start_date"], "start_date param must be passed"
      assert_equal "2026-03-31", safe_params["end_date"], "end_date param must be passed"
    end
  end

  # --- Export Edge Cases ---

  test "export links with campaign_id passes it through to job safe_params" do
    Sidekiq::Testing.fake! do
      ExportLinkDataJob.jobs.clear

      post "#{API_PREFIX}/projects/#{@project.id}/exports/links",
        params: { active: true, sdk: false, campaign_id: "42" },
        headers: @headers
      assert_response :accepted

      assert_equal 1, ExportLinkDataJob.jobs.size, "must enqueue ExportLinkDataJob"
      safe_params = ExportLinkDataJob.jobs.first["args"][1]
      assert_equal "42", safe_params["campaign_id"], "campaign_id must be passed through"
      assert_equal true, safe_params["active"], "active must be cast to boolean true"
      assert_equal false, safe_params["sdk"], "sdk must be cast to boolean false"
    end
  end

  test "export links with empty string dates strips them from safe_params" do
    Sidekiq::Testing.fake! do
      ExportLinkDataJob.jobs.clear

      post "#{API_PREFIX}/projects/#{@project.id}/exports/links",
        params: { active: true, sdk: false, start_date: "", end_date: "   " },
        headers: @headers
      assert_response :accepted

      safe_params = ExportLinkDataJob.jobs.first["args"][1]
      assert_not safe_params.key?("start_date"), "empty string start_date must be stripped by .presence + .compact"
      assert_not safe_params.key?("end_date"), "whitespace-only end_date must be stripped by .presence + .compact"
    end
  end

  # --- Cross-Tenant ---

  test "export link data for another instance project returns 403 with no data" do
    post "#{API_PREFIX}/projects/#{@project_two.id}/exports/links",
      params: { active: true },
      headers: @headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Forbidden", json["error"]
    assert_not json.key?("message"), "403 must not leak export status"
  end

  test "export link data for another instance does not enqueue job" do
    Sidekiq::Testing.fake! do
      ExportLinkDataJob.jobs.clear

      post "#{API_PREFIX}/projects/#{@project_two.id}/exports/links",
        params: { active: true },
        headers: @headers
      assert_response :forbidden

      assert_equal 0, ExportLinkDataJob.jobs.size, "forbidden request must not enqueue any job"
    end
  end
end
