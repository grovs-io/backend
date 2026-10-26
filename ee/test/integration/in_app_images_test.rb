require "test_helper"
require "sidekiq/testing"
require_relative "../../../test/integration/auth_test_helper"

class InAppImagesTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include InAppFixtures
  fixtures :instances, :users, :instance_roles, :projects, :visitors, :devices

  PNG = "\x89PNG\r\n\x1A\n".b.freeze

  setup do
    @project = projects(:one)
    entitle!(@project.instance)
    @admin = doorkeeper_headers_for(users(:admin_user))
    @member = doorkeeper_headers_for(users(:member_user))
    clear_in_app_stamps(@project)
    @campaign = in_app_campaign(@project)
  end

  def file(type: "image/png", bytes: PNG, name: "a.png")
    Rack::Test::UploadedFile.new(StringIO.new(bytes), type, true, original_filename: name)
  end

  def url(slot) = "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}/images/#{slot}"
  def image = response.parsed_body["in_app_campaign"]["content"]["image"]

  test "an upload fills its slot, a second one gets a new address, and removal empties it" do
    with_env("S3_ASSET_PREFIX" => "https://cdn.example") do
      post url("portrait"), params: { image: file }, headers: @member
      assert_response :ok
      first = image["portrait"]
      assert_match(%r{\Ahttps://cdn\.example/}, first)
      assert_nil image["landscape"]

      post url("portrait"), params: { image: file(bytes: "#{PNG}2") }, headers: @member
      assert_not_equal first, image["portrait"]
      post url("landscape"), params: { image: file }, headers: @member
      assert image.values.all?
      assert @campaign.reload.launch!

      delete url("landscape"), headers: @admin
      assert_equal [true, nil], [image["portrait"].present?, image["landscape"]]
    end
  end

  test "a later save keeps the uploaded image, whatever it says about images" do
    with_env("S3_ASSET_PREFIX" => "https://cdn.example") do
      post url("portrait"), params: { image: file }, headers: @member
      address = image["portrait"]
      base = "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}"

      [{ title: "Later" }, { title: "Later", image: { portrait: nil, landscape: nil } },
       { title: "Later", image: { portrait: "https://elsewhere.example/x.png", landscape: nil } }].each do |content|
        patch base, params: { content: content }, headers: @member, as: :json
        assert_response :ok
        assert_equal [address, nil], image.values_at("portrait", "landscape")
      end

      delete url("portrait"), headers: @member
      assert_nil image["portrait"]
      patch base, params: { content: { title: "Later" } }, headers: @member, as: :json
      assert_nil response.parsed_body.dig("in_app_campaign", "content", "image", "portrait")
    end
  end

  test "a copy has files of its own, so it keeps its picture when the original loses it" do
    with_env("S3_ASSET_PREFIX" => "https://cdn.example") do
      post url("portrait"), params: { image: file }, headers: @member
      original = image["portrait"]
      post "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}/duplicate", headers: @member, as: :json
      assert_response :created
      copy = InAppCampaign.find_by_hashid(response.parsed_body["in_app_campaign"]["id"])
      assert copy.portrait_image.attached?
      assert_not_equal @campaign.reload.portrait_image.blob.id, copy.portrait_image.blob.id
      assert_not_equal original, image["portrait"]
      assert_equal AssetService.permanent_url(copy.portrait_image), image["portrait"], "the copy answers with its own picture"
      assert_equal image["portrait"], copy.reload.content.dig("image", "portrait")

      @campaign.portrait_image.purge
      assert_equal PNG, copy.reload.portrait_image.download
    end
  end

  test "taps on the message itself, sent with an empty button id, are accepted" do
    @campaign.launch!
    assert InAppEventCheck.accept(project: @project, visitor: visitors(:ios_visitor), name: "in_app_clicked", event_id: "e1",
                                  properties: { "campaign_id" => @campaign.hashid, "button_id" => "" })
  end

  test "refuses a file that is not an image, one over 1 MB, and an unknown slot" do
    post url("portrait"), params: { image: file(type: "application/pdf", name: "a.pdf") }, headers: @member
    assert_response :unprocessable_entity
    post url("portrait"), params: { image: file(bytes: PNG + ("x" * 1.megabyte)) }, headers: @member
    assert_response :unprocessable_entity
    post url("square"), params: { image: file }, headers: @member
    assert_response :unprocessable_entity
    post url("portrait"), params: { image: "text" }, headers: @member
    assert_response :unprocessable_entity
    assert_not @campaign.reload.portrait_image.attached?
  end

  test "a launched campaign takes images from a member" do
    @campaign.launch!
    post url("portrait"), params: { image: file }, headers: @member
    assert_response :ok
  end

  private

  test "a removal the campaign refuses leaves the picture and its file" do
    with_env("S3_ASSET_PREFIX" => "https://cdn.example") do
      @campaign.update!(template: "interstitial_image", content: {})
      post url("portrait"), params: { image: file }, headers: @admin
      assert_response :ok
      @campaign.reload.launch!
      Sidekiq::Testing.fake! do
        Sidekiq::Job.clear_all
        delete url("portrait"), headers: @admin
        assert_empty(Sidekiq::Job.jobs.select { |job| job.to_json.include?("PurgeJob") })
      end
      assert_response :unprocessable_entity
      assert @campaign.reload.portrait_image.attached?
      assert_equal PNG, @campaign.portrait_image.download
    end
  end

  test "a copy keeps a picture the original only named by its address" do
    @campaign.update!(content: CONTENT.merge("image" => { "portrait" => "https://img.example/a.png", "landscape" => nil }))
    post "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}/duplicate", headers: @member, as: :json
    assert_response :created
    assert_equal "https://img.example/a.png", image["portrait"]
  end

  test "a copy whose pictures cannot be copied is not left behind" do
    post url("portrait"), params: { image: file }, headers: @member
    # minitest-mock has no stub_any_instance; swap the method on the class and restore it after.
    original = InAppCampaign.instance_method(:copy_images_from)
    InAppCampaign.define_method(:copy_images_from) { |_source| false }
    assert_no_difference -> { InAppCampaign.count } do
      post "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}/duplicate", headers: @member, as: :json
    end
    assert_response :unprocessable_entity
  ensure
    InAppCampaign.define_method(:copy_images_from, original)
  end

  test "a copy goes without a picture whose file is missing from storage" do
    post url("portrait"), params: { image: file }, headers: @member
    @campaign.reload.portrait_image.blob.service.delete(@campaign.portrait_image.blob.key)
    post "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}/duplicate", headers: @member, as: :json
    assert_response :created
    assert_nil image["portrait"]
  end

  test "a file is judged by its bytes, not by the type it claims" do
    post url("portrait"), params: { image: file(bytes: "%PDF-1.4 not a picture") }, headers: @member
    assert_response :unprocessable_entity
    assert_not @campaign.reload.portrait_image.attached?
  end

  test "an ended campaign takes and loses no picture" do
    @campaign.launch!
    @campaign.end!
    post url("portrait"), params: { image: file }, headers: @admin
    assert_response :conflict
    delete url("portrait"), headers: @admin
    assert_response :conflict
  end

  def with_env(values)
    old = values.keys.index_with { |key| ENV.fetch(key, nil) }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    old.each { |key, value| ENV[key] = value }
  end
end
