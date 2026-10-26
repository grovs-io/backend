require "test_helper"
require "sidekiq/testing"
require_relative "../../../test/integration/auth_test_helper"

class JourneysApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include JourneyFixtures
  fixtures :instances, :users, :instance_roles, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    entitle!(@project.instance)
    @admin = doorkeeper_headers_for(users(:admin_user))
    @member = doorkeeper_headers_for(users(:member_user))
    Sidekiq::Testing.fake!
  end

  teardown { Sidekiq::Testing.disable! }

  def base = "#{API_PREFIX}/projects/#{@project.id}/journeys"
  def body = response.parsed_body
  def valid = { name: "Cart recovery", entry: ADD_TO_CART, re_entry: { mode: "once", days: nil }, goals: [{ event: "checkout", window_hours: 168 }],
                control_group: 10, first_step: "s1", steps: map(step("s1", "wait", minutes: 60, next: "s2"), step("s2", "push")) }

  def created(headers = @admin, **attrs)
    post base, params: valid.merge(attrs), headers: headers, as: :json
    assert_response :created
    body["journey"]["id"]
  end

  test "needs a token and membership of the instance" do
    get base, headers: { "Host" => "api.sqd.link" }
    assert_response :unauthorized
    get "#{API_PREFIX}/projects/#{projects(:two).id}/journeys", headers: @member
    assert_response :forbidden
  end

  test "a member drafts, reads and edits a journey; the draft is audited" do
    id = created(@member)
    j = body["journey"]
    assert_equal ["draft", 1, false], [j["status"], j["revision"], j.key?("stats")]
    assert_equal ADD_TO_CART, j["entry"]
    assert_nil j["steps"]["s2"]["campaign_id"]
    assert AuditEvent.exists?(action: "journey.created")

    steps = valid[:steps].merge("s1" => step("s1", "wait", minutes: 30, next: "s2"))
    patch "#{base}/#{id}", params: { name: "Renamed", steps: steps }, headers: @member, as: :json
    assert_response :ok
    assert_equal ["Renamed", 30], [body["journey"]["name"], body["journey"]["steps"]["s1"]["minutes"]]
    get "#{base}/#{id}", headers: @member
    assert_response :ok
  end

  test "invalid maps and shapes are refused" do
    post base, params: valid.merge(steps: map(step("s1", "push", next: "s9"))), headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_match(/not a step/, body["error"])
    post base, params: valid.merge(entry: { type: "sms" }), headers: @admin, as: :json
    assert_response :unprocessable_entity
    post base, params: valid.merge(start_at: "soon"), headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_equal 0, Journey.count
  end

  test "a stale lock_version is a conflict" do
    id = created
    patch "#{base}/#{id}", params: { name: "A", lock_version: 0 }, headers: @admin, as: :json
    assert_response :ok
    patch "#{base}/#{id}", params: { name: "B", lock_version: 0 }, headers: @admin, as: :json
    assert_response :conflict
  end

  test "a member launches, pauses, resumes and ends; each refuses the wrong state" do
    id = created
    %w[pause resume end].each do |action|
      post "#{base}/#{id}/#{action}", headers: @member, as: :json
      assert_response :conflict
    end
    { "launch" => "live", "pause" => "paused", "resume" => "live", "end" => "ended" }.each do |action, status|
      post "#{base}/#{id}/#{action}", headers: @member, as: :json
      assert_response :ok
      assert_equal status, body["journey"]["status"]
    end
    assert_equal %w[journey.created journey.ended journey.launched journey.paused journey.resumed],
                 AuditEvent.where("action LIKE 'journey.%'").pluck(:action).sort
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    assert_response :conflict
  end

  test "launch lists the problems; a launched journey gives each send step its campaign" do
    id = created(steps: map(step("s1", "push", title: "")))
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_match(/Step s1: Title can't be blank/, body["error"])

    id = created
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    assert_response :ok
    assert_predicate body["journey"]["steps"]["s2"]["campaign_id"], :present?
    assert_not_nil body["journey"]["launched_at"]
  end

  test "after launch: a member edits, only content and timing, and never once ended" do
    id = created
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    steps = body["journey"]["steps"]
    patch "#{base}/#{id}", params: { steps: steps.merge("s2" => steps["s2"].merge("title" => "Hi again")) }, headers: @member, as: :json
    assert_response :ok
    assert_equal "Hi again", PushCampaign.find_by_hashid(steps["s2"]["campaign_id"]).title
    patch "#{base}/#{id}", params: { goals: [] }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_equal Journey::LOCKED, body["error"]

    delete "#{base}/#{id}", headers: @admin, as: :json
    assert_response :conflict
    post "#{base}/#{id}/end", headers: @admin, as: :json
    patch "#{base}/#{id}", params: { name: "x" }, headers: @admin, as: :json
    assert_response :conflict
  end

  test "duplicate makes a draft copy without the campaigns; delete takes a draft" do
    id = created
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    post "#{base}/#{id}/duplicate", headers: @member, as: :json
    assert_response :created
    copy = body["journey"]
    assert_equal ["Cart recovery copy", "draft", nil], [copy["name"], copy["status"], copy["steps"]["s2"]["campaign_id"]]
    delete "#{base}/#{copy['id']}", headers: @member, as: :json
    assert_response :ok
    assert AuditEvent.exists?(action: "journey.deleted")
  end

  test "the list is newest first, slim, paged and filtered" do
    ids = Array.new(3) { created }
    get base, params: { limit: 2 }, headers: @member
    assert_response :ok
    assert_equal ids.reverse.first(2), body["journeys"].pluck("id")
    assert(body["journeys"].none? { |j| j.key?("steps") })
    assert_equal({ "active" => 0, "entered" => 0 }, body["journeys"].first["stats"])
    get base, params: { limit: 2, after: body["next_after"] }, headers: @member
    assert_equal [ids.first], body["journeys"].pluck("id")
    get base, params: { status: "live" }, headers: @member
    assert_empty body["journeys"]
    get base, params: { after: "zz" }, headers: @member
    assert_response :unprocessable_entity
  end

  test "the report counts people per step and branch" do
    id = created(goals: [], control_group: nil)
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    j = Journey.find_by_hashid(id)
    signal(@project, seen(visitors(:ios_visitor), "add_to_cart"))
    get "#{base}/#{id}/report", headers: @member
    assert_response :ok
    report = body["report"]
    assert_equal [1, 0, 1, nil], report.values_at("entered", "held", "active", "goal")
    assert_equal({ "reached" => 1, "now" => 1, "branches" => { "next" => 0 } }, report["steps"]["s1"])
    get "#{base}/#{id}/report", params: { from: "bad" }, headers: @member
    assert_response :unprocessable_entity
    assert j.persisted?
  end

  test "a journey's channels stay out of the push and in-app lists and cannot be changed there" do
    id = created(steps: map(step("s1", "push", next: "s2"), step("s2", "in_app")))
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    steps = body["journey"]["steps"]
    get "#{API_PREFIX}/projects/#{@project.id}/push_campaigns", headers: @admin
    assert_empty body["push_campaigns"]
    get "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns", headers: @admin
    assert_empty body["in_app_campaigns"]
    post "#{API_PREFIX}/projects/#{@project.id}/in_app_campaigns/#{steps['s2']['campaign_id']}/pause", headers: @admin, as: :json
    assert_response :conflict
  end

  def upload(id, headers, bytes: "\x89PNG\r\n\x1A\n".b, type: "image/png", name: "a.png")
    post "#{base}/#{id}/images", params: { image: Rack::Test::UploadedFile.new(StringIO.new(bytes), type, true, original_filename: name) }, headers: headers
  end

  test "a step image is uploaded to the journey and its address handed back" do
    id = created(@member)
    upload(id, @member)
    assert_response :created
    assert_match(%r{/rails/active_storage/blobs/}, body["url"])
    upload(id, @member)
    assert_equal 2, Journey.find_by_hashid(id).images.count
    assert AuditEvent.exists?(action: "journey.updated")
  end

  test "an upload hands back the lock_version the next edit must send" do
    id = created(@member)
    upload(id, @member)
    version = body["lock_version"]
    assert_equal Journey.find_by_hashid(id).lock_version, version
    patch "#{base}/#{id}", params: { name: "After upload", lock_version: version }, headers: @member, as: :json
    assert_response :ok
    image = Rack::Test::UploadedFile.new(StringIO.new("\x89PNG\r\n\x1A\n".b), "image/png", true, original_filename: "b.png")
    post "#{base}/#{id}/images", params: { image: image, lock_version: version }, headers: @member
    assert_response :conflict
    assert_equal 1, Journey.find_by_hashid(id).images.count
  end

  test "an upload from an older lock_version is refused like a stale save and leaves no blob" do
    id = created(@member)
    stale = Journey.find_by_hashid(id).lock_version - 1
    patch "#{base}/#{id}", params: { name: "Edited", lock_version: stale }, headers: @member, as: :json
    assert_response :conflict
    expected = body

    image = Rack::Test::UploadedFile.new(StringIO.new("\x89PNG\r\n\x1A\n".b), "image/png", true, original_filename: "a.png")
    assert_no_difference("ActiveStorage::Blob.count") { post "#{base}/#{id}/images", params: { image: image, lock_version: stale }, headers: @member }
    assert_response :conflict
    assert_equal expected, body
    assert_not Journey.find_by_hashid(id).images.attached?
  end

  test "an upload answers the version it made, not a colleague's save landing before the answer" do
    id = created(@member)
    journey_id = Journey.find_by_hashid(id).id
    controller = Api::V1::JourneysController
    controller.define_method(:audit!) { |*| Journey.find(journey_id).update!(name: SecureRandom.hex(4)) }
    before = Journey.find(journey_id).lock_version
    upload(id, @member)
    assert_response :created
    assert_operator body["lock_version"], :>, before
    assert_equal Journey.find(journey_id).lock_version - 1, body["lock_version"]
  ensure
    controller.remove_method(:audit!)
  end

  test "a copy owns its images and its steps point at them; deleting the original keeps them" do
    id = created(@member)
    upload(id, @member)
    url = body["url"]
    upload(id, @member, name: "unused.png")
    steps = valid[:steps].merge("s2" => step("s2", "push", image_url: "https://cdn.example#{url}"))
    patch "#{base}/#{id}", params: { steps: steps }, headers: @member, as: :json
    assert_response :ok
    post "#{base}/#{id}/duplicate", headers: @member, as: :json
    copy = Journey.find_by_hashid(body["journey"]["id"])
    assert_equal 1, copy.images.count
    assert_not_includes copy.steps["s2"]["image_url"], url
    assert_includes copy.steps["s2"]["image_url"], AssetService.absolute_url(copy.images.blobs.first)
    originals = Journey.find_by_hashid(id).images.blobs.map(&:id)
    delete "#{base}/#{id}", headers: @member, as: :json
    assert_response :ok
    ActiveStorage::Blob.where(id: originals).find_each(&:purge)
    assert copy.reload.images.first.download.present?
  end

  test "a duplicate whose save fails after copying deletes the files it uploaded" do
    id = created(@member)
    upload(id, @member)
    steps = valid[:steps].merge("s2" => step("s2", "push", image_url: "https://cdn.example#{body['url']}"))
    patch "#{base}/#{id}", params: { steps: steps }, headers: @member, as: :json
    service = ActiveStorage::Blob.service
    uploaded = []
    upload_file = service.method(:upload)
    service.stub(:upload, ->(key, *args, **kw) { uploaded << key && upload_file.call(key, *args, **kw) }) do
      AssetService.stub(:swap, "broken") do
        assert_no_difference(["Journey.count", "ActiveStorage::Blob.count"]) { post "#{base}/#{id}/duplicate", headers: @member, as: :json }
      end
    end
    assert_response :unprocessable_entity
    assert_equal 1, uploaded.size
    assert_not service.exist?(uploaded.first)
  end

  test "an upload that is not an accepted type, or is over its size cap, is refused" do
    id = created(@member)
    upload(id, @member, bytes: "%PDF-1.4", type: "application/pdf", name: "a.pdf")
    assert_response :unprocessable_entity
    assert_equal "Image must be a PNG, JPEG, GIF, MP4, MP3 or M4A", body["error"]
    upload(id, @member, bytes: "\x89PNG\r\n\x1A\n".b + ("x" * 1.megabyte))
    assert_response :unprocessable_entity
    assert_equal "Image must be under 1 MB", body["error"]
    post "#{base}/#{id}/images", params: { image: "text" }, headers: @member
    assert_response :unprocessable_entity
    assert_not Journey.find_by_hashid(id).images.attached?
  end

  MP4 = (["00000018"].pack("H*") + "ftyp" + "isom" + ("\x00" * 8)).b.freeze
  M4A = (["00000018"].pack("H*") + "ftyp" + "M4A " + ("\x00" * 8)).b.freeze
  MP3 = ("ID3\x03\x00\x00\x00\x00\x00\x00" + ("\x00" * 20)).b.freeze

  test "a journey upload also accepts video and audio, within the shared count and size caps" do
    id = created(@member)
    upload(id, @member, bytes: MP4, type: "video/mp4", name: "a.mp4")
    assert_response :created
    upload(id, @member, bytes: MP3, type: "audio/mpeg", name: "a.mp3")
    assert_response :created
    upload(id, @member, bytes: M4A, type: "audio/mp4", name: "a.m4a")
    assert_response :created
    assert_equal 3, Journey.find_by_hashid(id).images.count

    journey = Journey.find_by_hashid(id)
    (InAppCampaign::MEDIA_COUNT_LIMIT - 3).times { journey.images.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "p.png", content_type: "image/png") }
    upload(id, @member)
    assert_response :unprocessable_entity
    assert_equal "Image a journey can hold at most #{InAppCampaign::MEDIA_COUNT_LIMIT} files", body["error"]
  end

  test "a journey's media cannot exceed 100 MB in total" do
    id = created(@member)
    journey = Journey.find_by_hashid(id)
    journey.images.attach(io: StringIO.new(MP4), filename: "a.mp4", content_type: "video/mp4")
    journey.images.blobs.last.update_column(:byte_size, 100.megabytes)
    upload(id, @member, bytes: MP4, type: "video/mp4", name: "b.mp4")
    assert_response :unprocessable_entity
    assert_equal "Image a journey can hold at most 100 MB of media", body["error"]
  end

  test "a launched journey takes images from a member" do
    id = created
    post "#{base}/#{id}/launch", headers: @admin, as: :json
    upload(id, @member)
    assert_response :created
  end

  test "journeys are not found where in-app messages are not enabled" do
    original = Instance.instance_method(:journeys_enabled?)
    Instance.define_method(:journeys_enabled?) { false }
    get base, headers: @member
    assert_response :not_found
    assert_equal "Journeys are not enabled", body["error"]
  ensure
    Instance.define_method(:journeys_enabled?, original)
  end
end
