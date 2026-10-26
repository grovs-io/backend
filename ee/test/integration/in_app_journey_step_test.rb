require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class InAppJourneyStepTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include InAppFixtures
  fixtures :instances, :users, :instance_roles, :projects, :visitors, :devices

  PNG = "\x89PNG\r\n\x1A\n".b.freeze

  setup do
    @project = projects(:one)
    entitle!(@project.instance)
    @admin = doorkeeper_headers_for(users(:admin_user))
    clear_in_app_stamps(@project)
    @campaign = in_app_campaign(@project, audience_type: "journey", segment_key: "j:1")
  end

  def base = "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}"
  def file = Rack::Test::UploadedFile.new(StringIO.new(PNG), "image/png", true, original_filename: "a.png")

  test "a journey step's message cannot be changed, copied or re-targeted from in-app campaigns" do
    before = @project.in_app_campaigns.count
    [[:post, "#{base}/images/portrait", { image: file }], [:delete, "#{base}/images/portrait", {}],
     [:post, "#{base}/media", { file: file }], [:delete, "#{base}/media/x", {}],
     [:post, "#{base}/duplicate", {}], [:post, "#{base}/update_audience", {}]].each do |verb, path, params|
      send(verb, path, params: params, headers: @admin)
      assert_response :conflict, "#{verb} #{path}"
      assert_match(/belongs to a journey/, response.parsed_body["error"])
    end
    assert_equal before, @project.in_app_campaigns.count
    assert_empty @campaign.reload.media.blobs
  end

  test "a journey step's message can still be read and sent as a test" do
    get base, headers: @admin
    assert_response :ok
    get "#{base}/media", headers: @admin
    assert_response :ok
    post "#{base}/test", params: { identifier: "nobody-here" }, headers: @admin
    assert_response :unprocessable_entity
    assert_match(/identifier/, response.parsed_body["error"])
  end
end
