require "test_helper"
require "sidekiq/testing"
require_relative "../../../test/integration/auth_test_helper"

class JourneysApiEdgeCasesTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include JourneyFixtures
  fixtures :instances, :users, :instance_roles, :projects, :visitors, :devices

  PNG = "\x89PNG\r\n\x1A\n".b.freeze

  setup do
    @project = projects(:one)
    entitle!(@project.instance)
    @member = doorkeeper_headers_for(users(:member_user))
    Sidekiq::Testing.fake!
  end

  teardown { Sidekiq::Testing.disable! }

  def base = "#{API_PREFIX}/projects/#{@project.id}/journeys"
  def body = response.parsed_body
  def valid = { name: "Cart recovery", entry: ADD_TO_CART, first_step: "s1", steps: map(step("s1", "wait", minutes: 60, next: "s2"), step("s2", "push")) }

  def created(**attrs)
    post base, params: valid.merge(attrs), headers: @member, as: :json
    assert_response :created
    body["journey"]["id"]
  end

  def upload(id, name: "a.png", **params)
    post "#{base}/#{id}/images", params: { image: Rack::Test::UploadedFile.new(StringIO.new(PNG), "image/png", true, original_filename: name) }.merge(params),
                                 headers: @member
  end

  test "a start time is stored, read back, and cleared by an empty value" do
    id = created(start_at: "2026-11-01T09:00:00Z")
    assert_equal Time.utc(2026, 11, 1, 9), Time.iso8601(body["journey"]["start_at"])
    assert_equal Time.utc(2026, 11, 1, 9), Journey.find_by_hashid(id).start_at

    patch "#{base}/#{id}", params: { start_at: "" }, headers: @member, as: :json
    assert_response :ok
    assert_nil body["journey"]["start_at"]
    assert_nil Journey.find_by_hashid(id).start_at

    patch "#{base}/#{id}", params: { end_at: "next week" }, headers: @member, as: :json
    assert_response :unprocessable_entity
    assert_equal "end_at must be a time such as 2026-10-01T09:00:00Z", body["error"]
  end

  test "an upload whose lock_version is not a number is refused and stores no file" do
    id = created
    assert_no_difference("ActiveStorage::Blob.count") { upload(id, lock_version: "v2") }
    assert_response :unprocessable_entity
    assert_equal "lock_version must be a number", body["error"]
    assert_not Journey.find_by_hashid(id).images.attached?
  end

  test "a lock_version past the column's range is a 422, not a crash" do
    id = created
    patch "#{base}/#{id}", params: { name: "Renamed", lock_version: 2**40 }, headers: @member, as: :json
    assert_response :unprocessable_entity
    assert_equal "A value is missing or out of range", body["error"]
    assert_equal "Cart recovery", Journey.find_by_hashid(id).name
  end

  test "a limit that is not a number is refused like a bad cursor" do
    created
    get base, params: { limit: "ten" }, headers: @member
    assert_response :unprocessable_entity
    assert_equal "after must be a journey id and limit an integer", body["error"]
  end

  test "a report while ClickHouse is down is a retryable 503 with its code" do
    id = created
    Journeys::Report.stub(:call, ->(*, **) { raise Clickhouse::Unavailable, "journey report" }) { get "#{base}/#{id}/report", headers: @member }
    assert_response :service_unavailable
    assert_equal({ "error" => "Reports are unavailable right now", "error_code" => "clickhouse_unavailable" }, body)
  end

  test "a copy goes without an image whose file is gone from storage, and keeps the ones it could copy" do
    id = created
    upload(id, name: "kept.png")
    kept = body["url"]
    upload(id, name: "lost.png")
    lost = body["url"]
    steps = valid[:steps].merge("s2" => step("s2", "push", image_url: "https://cdn.example#{kept}"),
                                "s3" => step("s3", "push", image_url: "https://cdn.example#{lost}"))
    patch "#{base}/#{id}", params: { steps: steps.merge("s2" => steps["s2"].merge("next" => "s3")) }, headers: @member, as: :json
    assert_response :ok
    gone = Journey.find_by_hashid(id).images.blobs.find { |b| b.filename.to_s == "lost.png" }
    gone.service.delete(gone.key)

    post "#{base}/#{id}/duplicate", headers: @member, as: :json
    assert_response :created
    copy = Journey.find_by_hashid(body["journey"]["id"])
    assert_equal ["kept.png"], copy.images.blobs.map { |b| b.filename.to_s }
    assert_includes copy.steps["s2"]["image_url"], AssetService.absolute_url(copy.images.blobs.first)
    assert_equal "https://cdn.example#{lost}", copy.steps["s3"]["image_url"], "the lost one keeps the address it had"
  end
end
