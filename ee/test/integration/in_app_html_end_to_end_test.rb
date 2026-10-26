require "test_helper"
require "zlib"
require "stringio"
require_relative "../../../test/integration/auth_test_helper"

class InAppHtmlEndToEndTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include InAppFixtures

  fixtures :instances, :users, :instance_roles, :projects, :applications, :ios_configurations, :android_configurations, :devices, :visitors

  HTML = '<div class="card"><h1>Hi {{ user.name | default: "there" }}</h1><button data-grovs-action="close">OK</button></div>'.freeze

  setup do
    @project = projects(:one)
    entitle!(@project.instance)
    @admin = doorkeeper_headers_for(users(:admin_user))
    @sdk = sdk_headers_for(@project, visitors(:ios_visitor), platform: "ios")
    clear_in_app_stamps(@project)
  end

  def base = "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns"

  def launched_html_campaign
    post base, params: { name: "Html", template: "html", content: { html: HTML, layout: "banner_bottom" }, triggers: TRIGGERS },
               headers: @admin, as: :json
    assert_response :created
    id = response.parsed_body["in_app_campaign"]["id"]
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    assert_response :accepted
    id
  end

  def assert_delivered(body, id)
    definition = body["campaigns"].find { |c| c["id"] == id }
    assert definition, "campaign #{id} not in sync"
    assert_equal "html", definition["template"]
    assert_equal "banner_bottom", definition.dig("content", "layout")
    assert_equal HTML, definition.dig("content", "html")
    assert_empty InAppDefinition.problems(definition)
  end

  test "an html campaign made and launched in the dashboard reaches the device with its layout and page" do
    id = launched_html_campaign
    post "#{SDK_PREFIX}/in_app/sync", params: { format: 1, sdk_version: "4.0.0" }, headers: @sdk, as: :json
    assert_response :ok
    assert_delivered(response.parsed_body, id)
  end

  test "the html page survives a gzipped sync unchanged" do
    id = launched_html_campaign
    raw = ActionDispatch::Integration::Session.new(Rails.application)
    raw.post "#{SDK_PREFIX}/in_app/sync", params: { format: 1, sdk_version: "4.0.0" }, headers: @sdk.merge("Accept-Encoding" => "gzip"), as: :json
    assert_equal 200, raw.response.status
    assert_equal "gzip", raw.response.headers["Content-Encoding"]
    assert_delivered(JSON.parse(Zlib::GzipReader.new(StringIO.new(raw.response.body)).read), id)
  end
end
