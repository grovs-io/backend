require "test_helper"
require_relative "auth_test_helper"

class EventsSearchApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :applications, :ios_configurations,
           :android_configurations, :web_configurations

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @headers = doorkeeper_headers_for(@admin_user)
  end

  def search_params
    { active: "true", sdk: "false", page: 1 }
  end

  test "events search and sorted answer 200 for a project with a domain" do
    post "#{API_PREFIX}/projects/#{@project.id}/events/search", params: search_params, headers: @headers
    assert_equal 200, response.status, response.body
    post "#{API_PREFIX}/projects/#{@project.id}/events/sorted", params: search_params.merge(event_type: "view"), headers: @headers
    assert_equal 200, response.status, response.body
  end

  test "events search and sorted answer 404, not 204 or 500, when the project has no domain" do
    domains(:one).destroy!
    post "#{API_PREFIX}/projects/#{@project.id}/events/search", params: search_params, headers: @headers
    assert_response :not_found
    assert_equal "Domain not found", JSON.parse(response.body)["error"]
    post "#{API_PREFIX}/projects/#{@project.id}/events/sorted", params: search_params.merge(event_type: "view"), headers: @headers
    assert_response :not_found
    assert_equal "Domain not found", JSON.parse(response.body)["error"]
  end
end
