require "test_helper"
require_relative "auth_test_helper"

class ServerApiCeTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects

  test "the CE build does not route the segment and in-app server API" do
    skip "the EE build routes it" if Grovs.ee?

    get "#{SDK_PREFIX}/server/segments", headers: server_sdk_headers_for(projects(:one))
    assert_response :not_found
    post "#{SDK_PREFIX}/server/in_app_campaigns", headers: server_sdk_headers_for(projects(:one)), as: :json
    assert_response :not_found
  end
end
