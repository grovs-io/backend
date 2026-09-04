# frozen_string_literal: true

require "test_helper"
require_relative "auth_test_helper"

class AdminRetentionTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances

  ADMIN_KEY = "test-admin-key"

  setup do
    @original_admin_key = ENV["ADMIN_API_KEY"]
    ENV["ADMIN_API_KEY"] = ADMIN_KEY
    @instance = instances(:two)
    @instance.update!(cold_storage_days: 365, delete_days: 730)
  end

  teardown { ENV["ADMIN_API_KEY"] = @original_admin_key }

  def admin_headers
    { "X-AUTH" => ADMIN_KEY, "Host" => api_host }
  end

  test "sets retention fields with a valid admin key" do
    patch "#{API_PREFIX}/admin/instance_retention",
          params: { instance_id: @instance.id, cold_storage_days: 365, delete_days: 1825 },
          headers: admin_headers

    assert_response :ok
    @instance.reload
    assert_equal 365, @instance.cold_storage_days
    assert_equal 1825, @instance.delete_days
    body = JSON.parse(response.body)
    assert_equal 365, body["cold_storage_days"]
    assert_equal 1825, body["delete_days"]
  end

  test "rejects without an admin key" do
    patch "#{API_PREFIX}/admin/instance_retention",
          params: { instance_id: @instance.id, delete_days: 1825 },
          headers: { "Host" => api_host }

    assert_response :forbidden
    assert_equal 730, @instance.reload.delete_days
  end

  test "returns 404 for an unknown instance" do
    patch "#{API_PREFIX}/admin/instance_retention",
          params: { instance_id: 0, delete_days: 1825 },
          headers: admin_headers

    assert_response :not_found
  end

  test "rejects delete_days shorter than cold_storage_days" do
    patch "#{API_PREFIX}/admin/instance_retention",
          params: { instance_id: @instance.id, cold_storage_days: 730, delete_days: 365 },
          headers: admin_headers

    assert_response :unprocessable_entity
    assert_equal 730, @instance.reload.delete_days, "invalid update must not persist"
  end

  test "rejects non-positive retention" do
    patch "#{API_PREFIX}/admin/instance_retention",
          params: { instance_id: @instance.id, cold_storage_days: 0 },
          headers: admin_headers

    assert_response :unprocessable_entity
    assert_equal 365, @instance.reload.cold_storage_days
  end

  test "rejects non-integer retention values" do
    patch "#{API_PREFIX}/admin/instance_retention",
          params: { instance_id: @instance.id, delete_days: "soon" },
          headers: admin_headers

    assert_response :unprocessable_entity
    assert_equal 730, @instance.reload.delete_days
  end
end
