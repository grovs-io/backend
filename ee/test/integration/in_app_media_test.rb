require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class InAppMediaTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include InAppFixtures
  fixtures :instances, :users, :instance_roles, :projects, :visitors, :devices

  PNG = "\x89PNG\r\n\x1A\n".b.freeze
  MP4 = (["00000018"].pack("H*") + "ftyp" + "isom" + ("\x00" * 8)).b.freeze
  M4A = (["00000018"].pack("H*") + "ftyp" + "M4A " + ("\x00" * 8)).b.freeze
  MP3 = ("ID3\x03\x00\x00\x00\x00\x00\x00" + ("\x00" * 20)).b.freeze

  setup do
    @project = projects(:one)
    entitle!(@project.instance)
    @admin = doorkeeper_headers_for(users(:admin_user))
    @member = doorkeeper_headers_for(users(:member_user))
    clear_in_app_stamps(@project)
    @campaign = in_app_campaign(@project)
  end

  def media_url(media_id = nil) = "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}/media#{"/#{media_id}" if media_id}"
  def file(type: "image/png", bytes: PNG, name: "a.png") = Rack::Test::UploadedFile.new(StringIO.new(bytes), type, true, original_filename: name)

  def upload(headers: @member, **opts)
    post media_url, params: { file: file(**opts) }, headers: headers
  end

  test "each accepted type uploads, read by its bytes, and lists with the expected shape" do
    upload(type: "image/png", bytes: PNG, name: "a.png")
    assert_response :created
    media = response.parsed_body["media"]
    assert_equal "image/png", media["type"]
    assert_equal PNG.bytesize, media["bytes"]
    assert_not media["used"]
    assert_match(%r{/rails/active_storage/blobs/}, media["url"])

    upload(type: "video/mp4", bytes: MP4, name: "a.mp4")
    assert_response :created
    assert_equal "video/mp4", response.parsed_body["media"]["type"]

    upload(type: "audio/mpeg", bytes: MP3, name: "a.mp3")
    assert_response :created
    assert_equal "audio/mpeg", response.parsed_body["media"]["type"]

    upload(type: "audio/mp4", bytes: M4A, name: "a.m4a")
    assert_response :created
    assert_equal "audio/mp4", response.parsed_body["media"]["type"]

    get media_url, headers: @member
    assert_response :ok
    assert_equal 4, response.parsed_body["media"].size
  end

  test "an M4A is accepted whatever type the browser declares, and stored as audio/mp4" do
    %w[audio/x-m4a application/octet-stream].each do |declared|
      upload(type: declared, bytes: M4A, name: "a.m4a")
      assert_response :created, declared
      assert_equal "audio/mp4", response.parsed_body["media"]["type"], declared
      assert_equal "audio/mp4", @campaign.reload.media.blobs.order(:id).last.content_type, declared
    end
  end

  test "upload and delete answer the campaign's new lock_version" do
    before = @campaign.lock_version
    upload
    assert_response :created
    assert_equal @campaign.reload.lock_version, response.parsed_body["lock_version"]
    assert_operator response.parsed_body["lock_version"], :>=, before

    delete media_url(response.parsed_body["media"]["id"]), headers: @member
    assert_response :ok
    assert_equal "Deleted", response.parsed_body["message"]
    assert_equal @campaign.reload.lock_version, response.parsed_body["lock_version"]
  end

  test "upload and delete answer the version they made, not a colleague's save landing before the answer" do
    controller = Api::V1::InAppCampaignsController
    controller.define_method(:audit!) { |*| InAppCampaign.find(@campaign.id).update!(name: SecureRandom.hex(4)) }
    before = @campaign.lock_version
    upload
    assert_response :created
    assert_operator response.parsed_body["lock_version"], :>, before
    assert_equal @campaign.reload.lock_version - 1, response.parsed_body["lock_version"]

    before = @campaign.lock_version
    delete media_url(response.parsed_body["media"]["id"]), headers: @member
    assert_response :ok
    assert_operator response.parsed_body["lock_version"], :>, before
    assert_equal @campaign.reload.lock_version - 1, response.parsed_body["lock_version"]
  ensure
    controller.remove_method(:audit!)
  end

  test "a media upload or delete from an older lock_version is refused like a stale save" do
    stale = @campaign.lock_version - 1
    patch "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}", params: { name: "Edited", lock_version: stale },
                                                                                        headers: @member, as: :json
    assert_response :conflict
    expected = response.parsed_body

    post media_url, params: { file: file, lock_version: stale }, headers: @member
    assert_response :conflict
    assert_equal expected, response.parsed_body
    assert_empty @campaign.reload.media

    post media_url, params: { file: file, lock_version: @campaign.lock_version }, headers: @member
    assert_response :created
    id = response.parsed_body["media"]["id"]

    delete media_url(id), params: { lock_version: stale }, headers: @member
    assert_response :conflict
    assert_equal expected, response.parsed_body
    assert_equal 1, @campaign.reload.media.count

    delete media_url(id), params: { lock_version: "soon" }, headers: @member
    assert_response :unprocessable_entity

    delete media_url(id), params: { lock_version: @campaign.lock_version }, headers: @member
    assert_response :ok
    assert_empty @campaign.reload.media
  end

  test "a renamed text file is refused, judged by its bytes and not by its declared type" do
    upload(type: "image/png", bytes: "just text", name: "a.png")
    assert_response :unprocessable_entity
    assert_equal "Media must be a PNG, JPEG, GIF, MP4, MP3 or M4A", response.parsed_body["error"]
    assert_not @campaign.reload.media.attached?
  end

  test "each type has its own size cap" do
    upload(type: "image/png", bytes: PNG + ("x" * 1.megabyte))
    assert_response :unprocessable_entity
    assert_equal "Media must be under 1 MB", response.parsed_body["error"]

    upload(type: "video/mp4", bytes: MP4 + ("x" * 20.megabytes), name: "a.mp4")
    assert_response :unprocessable_entity
    assert_equal "Media must be under 20 MB", response.parsed_body["error"]

    upload(type: "audio/mpeg", bytes: MP3 + ("x" * 10.megabytes), name: "a.mp3")
    assert_response :unprocessable_entity
    assert_equal "Media must be under 10 MB", response.parsed_body["error"]

    upload(type: "audio/mp4", bytes: M4A + ("x" * 10.megabytes), name: "a.m4a")
    assert_response :unprocessable_entity
    assert_equal "Media must be under 10 MB", response.parsed_body["error"]
  end

  test "a 31st file is refused" do
    InAppCampaign::MEDIA_COUNT_LIMIT.times { |i| @campaign.media.attach(io: StringIO.new(PNG), filename: "p#{i}.png", content_type: "image/png") }
    upload
    assert_response :unprocessable_entity
    assert_equal "Media a campaign can hold at most #{InAppCampaign::MEDIA_COUNT_LIMIT} files", response.parsed_body["error"]
  end

  test "more than 100 MB total is refused" do
    @campaign.media.attach(io: StringIO.new(MP4), filename: "a.mp4", content_type: "video/mp4")
    @campaign.media.blobs.last.update_column(:byte_size, 100.megabytes)
    upload(type: "video/mp4", bytes: MP4, name: "b.mp4")
    assert_response :unprocessable_entity
    assert_equal "Media a campaign can hold at most 100 MB of media", response.parsed_body["error"]
  end

  test "deleting media in use is refused, and the audit and conflict checks match upload_image" do
    upload
    address = response.parsed_body["media"]["url"]
    id = response.parsed_body["media"]["id"]
    @campaign.reload.update!(content: @campaign.content.merge("html" => "<img src=\"#{address}\">"))

    delete media_url(id), headers: @member
    assert_response :conflict
    assert_equal "in_use", response.parsed_body["error"]
    assert @campaign.reload.media.attached?

    @campaign.update!(content: @campaign.content.except("html"))
    delete media_url(id), headers: @member
    assert_response :ok
    assert_not @campaign.reload.media.attached?
    assert AuditEvent.exists?(action: "in_app_campaign.updated")
  end

  test "the media list marks a file used only when the campaign html names it" do
    upload(name: "used.png")
    address = response.parsed_body["media"]["url"]
    upload(name: "unused.png")
    @campaign.reload.update!(content: @campaign.content.merge("html" => "<img src=\"#{address}\">"))

    get media_url, headers: @member
    assert_response :ok
    used = response.parsed_body["media"].to_h { |m| [m["url"], m["used"]] }
    assert_equal true, used.delete(address)
    assert_equal [false], used.values
  end

  test "deleting unknown media answers not found" do
    delete media_url("not-a-real-signed-id"), headers: @member
    assert_response :not_found
  end

  test "an ended campaign takes and loses no media" do
    @campaign.media.attach(io: StringIO.new(PNG), filename: "p.png", content_type: "image/png")
    id = @campaign.media.blobs.last.signed_id
    @campaign.launch!
    @campaign.end!

    upload(headers: @admin)
    assert_response :conflict
    delete media_url(id), headers: @admin
    assert_response :conflict
    assert @campaign.reload.media.attached?
  end

  test "a launched campaign takes and removes media from a member" do
    @campaign.launch!
    upload(headers: @member)
    assert_response :created
    id = response.parsed_body["media"]["id"]
    delete media_url(id), headers: @member
    assert_response :ok
  end

  test "on a live campaign, media upload and delete leave the campaigns stamp; a content edit and a pause move it" do
    @campaign.launch!
    stamp = InAppStamps.campaigns(@project.id)
    travel(1.second) do
      upload(headers: @admin)
      assert_response :created
      delete media_url(response.parsed_body["media"]["id"]), headers: @admin
      assert_response :ok
    end
    assert_equal stamp, InAppStamps.campaigns(@project.id)

    travel(2.seconds) { @campaign.reload.update!(content: @campaign.content.merge("title" => "New title")) }
    assert_not_equal stamp, (stamp = InAppStamps.campaigns(@project.id))
    travel(3.seconds) { assert @campaign.transition!(from: %w[live], to: "paused") }
    assert_not_equal stamp, InAppStamps.campaigns(@project.id)
  end

  test "a duplicate whose save fails after copying deletes the files it uploaded" do
    upload(name: "used.png")
    @campaign.reload.update!(content: @campaign.content.merge("html" => "<img src=\"#{response.parsed_body['media']['url']}\">"))
    @campaign.portrait_image.attach(io: StringIO.new(PNG), filename: "p.png", content_type: "image/png")
    service = ActiveStorage::Blob.service
    uploaded = []
    upload_file = service.method(:upload)
    service.stub(:upload, ->(key, *args, **kw) { uploaded << key && upload_file.call(key, *args, **kw) }) do
      AssetService.stub(:swap, "broken") do
        assert_no_difference(["InAppCampaign.count", "ActiveStorage::Blob.count"]) do
          post "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}/duplicate", headers: @member, as: :json
        end
      end
    end
    assert_response :unprocessable_entity
    assert_equal 1, uploaded.size, "the picture uploads only after commit, so only the media copy reached storage"
    assert_not service.exist?(uploaded.first)
  end

  test "a duplicate copies only the media its html and its variants' html reference, and rewrites the addresses" do
    upload(name: "used_a.png")
    address_a = response.parsed_body["media"]["url"]
    upload(name: "used_b.png")
    address_b = response.parsed_body["media"]["url"]
    upload(name: "unused.png")

    @campaign.reload.update!(content: @campaign.content.merge("html" => "<img src=\"#{address_a}\">"),
                             variants: [{ "id" => "b", "content" => { "html" => "<img src=\"#{address_b}\">" } }])

    post "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}/duplicate", headers: @member, as: :json
    assert_response :created
    copy = InAppCampaign.find_by_hashid(response.parsed_body["in_app_campaign"]["id"])

    assert_equal 2, copy.media.count
    assert_not_includes copy.content["html"], address_a
    assert_includes copy.content["html"], AssetService.absolute_url(copy.media.blobs.find { |b| b.filename.to_s == "used_a.png" })
    assert_not_includes copy.variants.first["content"]["html"], address_b
    assert_includes copy.variants.first["content"]["html"], AssetService.absolute_url(copy.media.blobs.find { |b| b.filename.to_s == "used_b.png" })
  end

  test "duplicate with a variant copies only that variant's media, not a's or another variant's" do
    upload(name: "a_only.png")
    address_a = response.parsed_body["media"]["url"]
    upload(name: "b_only.png")
    address_b = response.parsed_body["media"]["url"]
    upload(name: "c_only.png")
    address_c = response.parsed_body["media"]["url"]

    @campaign.reload.update!(content: @campaign.content.merge("html" => "<img src=\"#{address_a}\">"),
                             variants: [{ "id" => "b", "content" => { "html" => "<img src=\"#{address_b}\">" } },
                                        { "id" => "c", "content" => { "html" => "<img src=\"#{address_c}\">" } }])

    post "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{@campaign.hashid}/duplicate", params: { variant: "b" }, headers: @member, as: :json
    assert_response :created
    copy = InAppCampaign.find_by_hashid(response.parsed_body["in_app_campaign"]["id"])

    assert_nil copy.variants
    assert_equal 1, copy.media.count
    assert_equal "b_only.png", copy.media.blobs.first.filename.to_s
    assert_includes copy.content["html"], AssetService.absolute_url(copy.media.blobs.first)
  end

  test "a media url is absolute even when S3_ASSET_PREFIX is unset" do
    with_env("S3_ASSET_PREFIX" => nil, "SERVER_HOST_PROTOCOL" => "https://", "SERVER_HOST" => "example.com") do
      upload
      assert_response :created
      assert_equal "https://api.example.com#{AssetService.permanent_url(@campaign.reload.media.blobs.last)}", response.parsed_body["media"]["url"]

      get media_url, headers: @member
      assert response.parsed_body["media"].first["url"].start_with?("https://api.example.com")
    end
  end

  test "another instance's campaign: media list, upload and delete are refused and touch nothing" do
    foreign = in_app_campaign(projects(:two))
    foreign.media.attach(io: StringIO.new(PNG), filename: "f.png", content_type: "image/png")
    id = foreign.media.blobs.last.signed_id
    via_foreign = "#{API_PREFIX}/projects/#{projects(:two).id}/in_app_campaigns/#{foreign.hashid}/media"
    via_own = "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{foreign.hashid}/media"

    [[via_foreign, :forbidden], [via_own, :not_found]].each do |base, status|
      get base, headers: @admin
      assert_response status, base
      post base, params: { file: file }, headers: @admin
      assert_response status, base
      delete "#{base}/#{id}", headers: @admin
      assert_response status, base
    end
    assert_equal 1, foreign.reload.media.count
    assert_empty @campaign.reload.media
  end

  test "deleting another campaign's media through this campaign's route is not found and leaves it attached" do
    neighbour = in_app_campaign(@project)
    foreign = in_app_campaign(projects(:two))
    [neighbour, foreign].each { |c| c.media.attach(io: StringIO.new(PNG), filename: "x.png", content_type: "image/png") }
    upload
    assert_response :created

    [neighbour, foreign].each do |other|
      delete media_url(other.media.blobs.last.signed_id), headers: @admin
      assert_response :not_found
      assert_equal 1, other.reload.media.count
    end
    assert_equal 1, @campaign.reload.media.count
  end

  def with_env(values)
    old = values.keys.index_with { |key| ENV.fetch(key, nil) }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    old.each { |key, value| ENV[key] = value }
  end
end
