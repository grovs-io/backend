require "test_helper"
require "zlib"
require "stringio"
require_relative "../../../test/integration/auth_test_helper"

# Uses a raw ActionDispatch::Integration::Session (not the ActionDispatch::IntegrationTest
# helpers) so the ApiContracts hook never tries to JSON-parse a gzipped body.
class InAppSyncCompressionTest < ActiveSupport::TestCase
  include AuthTestHelper
  include InAppFixtures

  fixtures :instances, :projects, :applications, :ios_configurations, :android_configurations, :devices, :visitors

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @headers = sdk_headers_for(@project, @visitor, platform: "ios")
    clear_in_app_stamps(@project)
  end

  def session = @session ||= ActionDispatch::Integration::Session.new(Rails.application)

  def gunzip(body) = Zlib::GzipReader.new(StringIO.new(body)).read

  test "gzips the in-app sync response when the client sends Accept-Encoding: gzip" do
    session.post "#{SDK_PREFIX}/in_app/sync", params: { format: 1, sdk_version: "4.0.0" },
                                               headers: @headers.merge("Accept-Encoding" => "gzip"), as: :json
    assert_equal 200, session.response.status
    assert_equal "gzip", session.response.headers["Content-Encoding"]
    body = JSON.parse(gunzip(session.response.body))
    assert body.key?("campaigns")
  end

  test "does not gzip the response when the client sends no Accept-Encoding" do
    session.post "#{SDK_PREFIX}/in_app/sync", params: { format: 1, sdk_version: "4.0.0" }, headers: @headers, as: :json
    assert_equal 200, session.response.status
    assert_nil session.response.headers["Content-Encoding"]
    assert JSON.parse(session.response.body).key?("campaigns")
  end

  test "does not gzip a different endpoint even when the client accepts it" do
    session.get "/up", headers: { "Accept-Encoding" => "gzip" }
    assert_equal 200, session.response.status
    assert_nil session.response.headers["Content-Encoding"]
  end
end
