require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class InAppApiEdgeCasesTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include InAppFixtures
  fixtures :instances, :users, :instance_roles, :projects, :visitors, :devices

  PNG = "\x89PNG\r\n\x1A\n".b.freeze

  setup do
    @project = projects(:one)
    entitle!(@project.instance)
    @member = doorkeeper_headers_for(users(:member_user))
    clear_in_app_stamps(@project)
  end

  def base = "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns"
  def settings = "#{API_PREFIX}/projects/#{@project.id}/in_app_settings"
  def body = response.parsed_body

  def upload(campaign, name)
    post "#{base}/#{campaign.hashid}/media", params: { file: Rack::Test::UploadedFile.new(StringIO.new(PNG), "image/png", true, original_filename: name) },
                                             headers: @member
    assert_response :created
    body["media"]["url"]
  end

  test "without in-app messages on the plan, campaigns and settings are not found and nothing is written" do
    original = Instance.instance_method(:in_app_enabled?)
    Instance.define_method(:in_app_enabled?) { false }
    get base, headers: @member
    assert_response :not_found
    assert_equal({ "error" => "In-app messages are not enabled" }, body)
    assert_no_difference("InAppCampaign.count") { post base, params: { name: "Welcome", content: CONTENT, triggers: TRIGGERS }, headers: @member, as: :json }
    assert_response :not_found
    patch settings, params: { session_cap: 3 }, headers: @member, as: :json
    assert_response :not_found
    assert_equal({ "error" => "In-app messages are not enabled" }, body)
    assert_equal 0, InAppSetting.where(project_id: @project.id).count
  ensure
    Instance.define_method(:in_app_enabled?, original)
  end

  test "a lock_version past the column's range is a 422, not a crash" do
    campaign = in_app_campaign(@project)
    patch "#{base}/#{campaign.hashid}", params: { name: "Renamed", lock_version: 2**40 }, headers: @member, as: :json
    assert_response :unprocessable_entity
    assert_equal "A value is missing or out of range", body["error"]
    assert_equal "Welcome", campaign.reload.name
  end

  test "a limit that is not a number is refused like a bad cursor" do
    get base, params: { limit: "ten" }, headers: @member
    assert_response :unprocessable_entity
    assert_equal "after must be an in-app campaign id and limit an integer", body["error"]
  end

  test "a copy goes without a media file gone from storage, and copies and rewrites the rest" do
    campaign = in_app_campaign(@project)
    kept = upload(campaign, "kept.png")
    lost = upload(campaign, "lost.png")
    campaign.reload.update!(template: "html", content: { "html" => "<img src=\"#{kept}\"><img src=\"#{lost}\">", "layout" => "modal" })
    gone = campaign.media.blobs.find { |b| b.filename.to_s == "lost.png" }
    gone.service.delete(gone.key)

    post "#{base}/#{campaign.hashid}/duplicate", headers: @member, as: :json
    assert_response :created
    copy = InAppCampaign.find_by_hashid(body["in_app_campaign"]["id"])
    assert_equal ["kept.png"], copy.media.blobs.map { |b| b.filename.to_s }
    assert_includes copy.content["html"], AssetService.absolute_url(copy.media.blobs.first)
    assert_not_includes copy.content["html"], kept
    assert_includes copy.content["html"], lost, "the lost file keeps the address it had"
  end
end
