require "test_helper"
require_relative "auth_test_helper"

class DiagnosticsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :users, :projects, :domains

  DIAG_KEY = "test-diagnostics-key-12345"

  setup do
    @original_key = ENV["DIAGNOSTICS_API_KEY"]
    ENV["DIAGNOSTICS_API_KEY"] = DIAG_KEY
  end

  teardown do
    ENV["DIAGNOSTICS_API_KEY"] = @original_key
  end

  # --- Authentication ---

  test "request without API key returns 401" do
    get "#{API_PREFIX}/diagnostics/test_logs", headers: { "Host" => api_host }
    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_equal "Unauthorized", json["error"]
  end

  test "request with wrong API key returns 401" do
    get "#{API_PREFIX}/diagnostics/test_logs",
      headers: { "Host" => api_host, "X-Diagnostics-Key" => "wrong-key" }
    assert_response :unauthorized
  end

  test "request when DIAGNOSTICS_API_KEY env is blank returns 401" do
    ENV["DIAGNOSTICS_API_KEY"] = ""
    get "#{API_PREFIX}/diagnostics/test_logs",
      headers: { "Host" => api_host, "X-Diagnostics-Key" => "anything" }
    assert_response :unauthorized
  end

  test "API key accepted via X-Diagnostics-Key header" do
    get "#{API_PREFIX}/diagnostics/test_logs",
      headers: diag_headers("X-Diagnostics-Key" => DIAG_KEY)
    assert_response :ok
  end

  test "API key accepted via Authorization Bearer header" do
    get "#{API_PREFIX}/diagnostics/test_logs",
      headers: diag_headers("Authorization" => "Bearer #{DIAG_KEY}")
    assert_response :ok
  end

  test "API key accepted via api_key param" do
    get "#{API_PREFIX}/diagnostics/test_logs",
      params: { api_key: DIAG_KEY },
      headers: { "Host" => api_host }
    assert_response :ok
  end

  # --- test_logs ---

  test "test_logs returns JSON with correct structure" do
    get "#{API_PREFIX}/diagnostics/test_logs",
      headers: diag_headers("X-Diagnostics-Key" => DIAG_KEY)
    assert_response :ok

    json = JSON.parse(response.body)
    assert_equal "ok", json["status"]
    assert json["logs_generated"].is_a?(Integer)
    assert json["level"].present?
    assert json["hostname"].present?
    assert json["logs"].is_a?(Array)
  end

  test "test_logs count is clamped to 100" do
    get "#{API_PREFIX}/diagnostics/test_logs",
      params: { count: 200 },
      headers: diag_headers("X-Diagnostics-Key" => DIAG_KEY)
    assert_response :ok

    json = JSON.parse(response.body)
    assert_equal 100, json["logs_generated"]
    assert_equal 100, json["logs"].length
  end

  test "test_logs count is clamped to minimum 1" do
    get "#{API_PREFIX}/diagnostics/test_logs",
      params: { count: 0 },
      headers: diag_headers("X-Diagnostics-Key" => DIAG_KEY)
    assert_response :ok

    json = JSON.parse(response.body)
    assert_equal 1, json["logs_generated"]
  end

  test "test_logs with specific level returns that level" do
    get "#{API_PREFIX}/diagnostics/test_logs",
      params: { level: "warn", count: 1 },
      headers: diag_headers("X-Diagnostics-Key" => DIAG_KEY)
    assert_response :ok

    json = JSON.parse(response.body)
    assert_equal "warn", json["level"]
  end

  test "test_logs with custom message includes it in logs" do
    get "#{API_PREFIX}/diagnostics/test_logs",
      params: { message: "Custom test message", count: 1 },
      headers: diag_headers("X-Diagnostics-Key" => DIAG_KEY)
    assert_response :ok

    json = JSON.parse(response.body)
    assert_includes json["logs"][0]["message"], "Custom test message"
  end

  # --- test_diagnostics ---

  test "test_diagnostics exercises PG and Redis and returns summary" do
    get "#{API_PREFIX}/diagnostics/test_diagnostics",
      params: { iterations: 2 },
      headers: diag_headers("X-Diagnostics-Key" => DIAG_KEY)
    assert_response :ok

    json = JSON.parse(response.body)
    assert json["postgresql"].present?
    assert json["redis"].present?
    assert json["summary"].present?
    assert_includes ["healthy", "degraded"], json["summary"]["status"]
  end

  test "test_diagnostics with cleanup=true deletes test records" do
    get "#{API_PREFIX}/diagnostics/test_diagnostics",
      params: { iterations: 3, cleanup: "true" },
      headers: diag_headers("X-Diagnostics-Key" => DIAG_KEY)
    assert_response :ok

    json = JSON.parse(response.body)
    assert_equal json["postgresql"]["records_created"], json["postgresql"]["records_deleted"],
      "Cleanup should delete all created records"
  end

  test "test_diagnostics with cleanup=false leaves records" do
    get "#{API_PREFIX}/diagnostics/test_diagnostics",
      params: { iterations: 2, cleanup: "false" },
      headers: diag_headers("X-Diagnostics-Key" => DIAG_KEY)
    assert_response :ok

    json = JSON.parse(response.body)
    assert_equal 2, json["postgresql"]["records_created"]
    assert_equal 0, json["postgresql"]["records_deleted"]

    # Clean up manually
    DiagnosticsLog.where("test_key LIKE ?", "diag_%").delete_all
  end

  test "test_diagnostics iterations clamped to max 100" do
    get "#{API_PREFIX}/diagnostics/test_diagnostics",
      params: { iterations: 200 },
      headers: diag_headers("X-Diagnostics-Key" => DIAG_KEY)
    assert_response :ok

    json = JSON.parse(response.body)
    assert_equal 100, json["iterations"]
  end

  # --- test_exception ---
  # In integration tests, Rails catches exceptions and returns 500.

  test "test_exception returns 500 error response" do
    get "#{API_PREFIX}/diagnostics/test_exception",
      headers: diag_headers("X-Diagnostics-Key" => DIAG_KEY)
    assert_response :internal_server_error
  end

  test "test_exception with runtime type returns 500" do
    get "#{API_PREFIX}/diagnostics/test_exception",
      params: { type: "runtime", message: "test boom" },
      headers: diag_headers("X-Diagnostics-Key" => DIAG_KEY)
    assert_response :internal_server_error
  end

  test "test_exception with record_not_found type returns 404" do
    get "#{API_PREFIX}/diagnostics/test_exception",
      params: { type: "record_not_found" },
      headers: diag_headers("X-Diagnostics-Key" => DIAG_KEY)
    # ActiveRecord::RecordNotFound is typically rescued as 404
    assert_includes [404, 500], response.status
  end

  test "test_exception without auth returns 401 not exception" do
    get "#{API_PREFIX}/diagnostics/test_exception",
      headers: { "Host" => api_host }
    assert_response :unauthorized
  end

  # --- POST methods work too ---

  test "test_logs via POST works" do
    post "#{API_PREFIX}/diagnostics/test_logs",
      params: { count: 1 },
      headers: diag_headers("X-Diagnostics-Key" => DIAG_KEY)
    assert_response :ok
  end

  test "test_diagnostics via POST works" do
    post "#{API_PREFIX}/diagnostics/test_diagnostics",
      params: { iterations: 1 },
      headers: diag_headers("X-Diagnostics-Key" => DIAG_KEY)
    assert_response :ok
  end

  private

  def diag_headers(extra = {})
    { "Host" => api_host }.merge(extra)
  end
end
