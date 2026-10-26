require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class EventDestinationsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include EventStreamTestHelper
  fixtures :instances, :users, :instance_roles, :projects

  setup do
    @project = projects(:one)
    @admin = doorkeeper_headers_for(users(:admin_user))
    @member = doorkeeper_headers_for(users(:member_user))
    @foreign = doorkeeper_headers_for(users(:super_admin_user))
    entitle!(instances(:one))
  end

  def base = "#{API_PREFIX}/projects/#{@project.id}/event_destinations"

  def create!(params = {})
    EventStream::Outbox.stub(:sync_project!, ->(_project) { true }) do
      post base, params: { name: "crm", kind: "webhook", settings: { url: "https://hooks.example.com/in" } }.merge(params), headers: @admin, as: :json
    end
    JSON.parse(response.body)
  end

  test "admin creates a webhook destination and receives the signing secret once" do
    body = create!
    assert_response :created
    assert_match(/\Awhsec_/, body["signing_secret"])
    d = body["event_destination"]
    assert_equal "crm", d["name"]
    assert_equal "enabled", d["status"]
    assert_equal EventDestination::DEFAULT_EVENT_TYPES, d["event_types"]
    assert_nil d["signing_secret"]

    get base, headers: @admin
    assert_response :ok
    assert_equal 1, JSON.parse(response.body)["event_destinations"].size
  end

  test "admin creates a custom S3 provider while private endpoints return a form validation error" do
    params = { name: "Hetzner", kind: "s3", settings: { bucket: "events", region: "fsn1", endpoint: "https://fsn1.your-objectstorage.com" },
               credentials: { access_key_id: "test-key", secret_access_key: "test-secret" } }
    body = create!(params)
    assert_response :created
    assert_equal params[:settings][:endpoint], body["event_destination"]["settings"]["endpoint"]
    assert_nil body["signing_secret"]
    with_resolver(["169.254.169.254"]) do
      assert_no_difference "EventDestination.count" do
        body = create!(params)
        assert_response :unprocessable_entity
        assert_includes body["error"], "endpoint must not resolve to a private address"
      end
    end
  end

  test "member gets 403 on writes but can list" do
    post base, params: { name: "x", kind: "webhook", settings: { url: "https://h.example.com" } }, headers: @member, as: :json
    assert_response :forbidden
    get base, headers: @member
    assert_response :ok
  end

  test "unentitled instance gets 402" do
    unentitle!(instances(:one))
    post base, params: { name: "x", kind: "webhook", settings: { url: "https://h.example.com" } }, headers: @admin, as: :json
    assert_response :payment_required
  end

  test "foreign admin cannot see or touch another tenant's destinations" do
    id = create!["event_destination"]["id"]
    get base, headers: @foreign
    assert_response :forbidden
    delete "#{base}/#{id}", headers: @foreign
    assert_response :forbidden
  end

  test "validation errors are 422 with the error envelope" do
    post base, params: { name: "x", kind: "kafka", settings: {} }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert JSON.parse(response.body)["error"].present?
  end

  test "update, pause, resume, rewind, delete" do
    id = create!["event_destination"]["id"]
    patch "#{base}/#{id}", params: { batch_size: 1, event_types: %w[install] }, headers: @admin, as: :json
    assert_response :ok
    assert_equal 1, JSON.parse(response.body)["event_destination"]["batch_size"]

    post "#{base}/#{id}/pause", headers: @admin
    assert_response :ok
    assert_equal "paused", JSON.parse(response.body)["event_destination"]["status"]

    post "#{base}/#{id}/resume", headers: @admin
    assert_response :ok
    assert_equal "enabled", JSON.parse(response.body)["event_destination"]["status"]

    post "#{base}/#{id}/rewind", params: { to: 2.days.ago.iso8601 }, headers: @admin, as: :json
    assert_response :ok
    assert_in_delta 2.days.ago.to_i, Time.iso8601(JSON.parse(response.body)["event_destination"]["events_cursor_at"]).to_i, 5

    post "#{base}/#{id}/rewind", params: { to: 30.days.ago.iso8601 }, headers: @admin, as: :json
    assert_response :unprocessable_entity

    post "#{base}/#{id}/rewind", params: { to: 1.day.from_now.iso8601 }, headers: @admin, as: :json
    assert_response :unprocessable_entity

    EventStream::Outbox.stub(:sync_project!, ->(_project) { true }) do
      delete "#{base}/#{id}", headers: @admin
    end
    assert_response :ok
    assert_equal 0, EventDestination.where(project: @project).count
  end

  test "test action sends one synthetic envelope through the adapter" do
    id = create!["event_destination"]["id"]
    posted = nil
    capture = lambda do |_url, opts|
      posted = opts[:body]
      Struct.new(:code, :body).new(200, "")
    end
    HTTParty.stub(:post, capture) do
      post "#{base}/#{id}/test", headers: @admin
    end
    assert_response :ok
    assert_equal "test", JSON.parse(posted)["type"]
  end

  test "a refused test event answers 424 with the endpoint's status" do
    id = create!["event_destination"]["id"]
    HTTParty.stub(:post, ->(*) { Struct.new(:code, :body).new(500, "boom") }) { post "#{base}/#{id}/test", headers: @admin }
    assert_response :failed_dependency
    assert_match(/500/, JSON.parse(response.body)["error"])
  end

  test "deleting a destination purges the outbox only after the delete commits" do
    id = create!["event_destination"]["id"]
    outside = ActiveRecord::Base.connection.open_transactions
    seen = nil
    probe = ->(_project) { seen = [ActiveRecord::Base.connection.open_transactions, EventDestination.exists?(id: EventDestination.decode_id(id))] }
    EventStream::Outbox.stub(:sync_project!, probe) do
      delete "#{base}/#{id}", headers: @admin
    end
    assert_response :ok
    assert_equal [outside, false], seen, "the ClickHouse purge must run after the Postgres transaction"
  end

  test "kind cannot change after creation" do
    id = create!["event_destination"]["id"]
    patch "#{base}/#{id}", params: { kind: "s3", settings: { bucket: "b", region: "eu-central-1" } }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_equal "webhook", EventDestination.find_by_hashid(id).kind
  end

  test "webhook urls that resolve to private addresses are rejected" do
    with_resolver(["169.254.169.254"]) do
      post base, params: { name: "x", kind: "webhook", settings: { url: "https://metadata.example.com" } }, headers: @admin, as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/private/, JSON.parse(response.body)["error"])
  end

  test "test action is refused while the kill switch is on" do
    id = create!["event_destination"]["id"]
    ENV["EVENT_STREAM_ENABLED"] = "false"
    HTTParty.stub(:post, ->(*) { flunk "must not deliver" }) { post "#{base}/#{id}/test", headers: @admin }
    assert_response :service_unavailable
  ensure
    ENV.delete("EVENT_STREAM_ENABLED")
  end

  test "audit rows are written" do
    create!
    assert AuditEvent.where(instance_id: instances(:one).id, action: "event_destination.created").exists?
  end

  test "an export older than the plan's retention is refused even when rollup reads are off" do
    start_date = 3.years.ago.to_date
    post "#{API_PREFIX}/projects/#{@project.id}/event_exports",
         params: { start_date: start_date.iso8601, end_date: (start_date + 1).iso8601 }, headers: @admin, as: :json
    assert_response :unprocessable_entity
    assert_equal "retention_window_exceeded", JSON.parse(response.body)["error_code"]
  end

  test "export request is queued and audited" do
    args = nil
    EventExportJob.stub(:perform_async, ->(*a) { args = a }) do
      post "#{API_PREFIX}/projects/#{@project.id}/event_exports", params: { start_date: "2026-09-01", end_date: "2026-09-02" }, headers: @admin, as: :json
    end
    assert_response :accepted
    assert_equal [@project.id, "2026-09-01", "2026-09-02", users(:admin_user).id, nil], args.first(5)
    assert args.last.present?, "each export carries an id for its resume checkpoint"
    assert AuditEvent.where(action: "export.event_data").exists?

    post "#{API_PREFIX}/projects/#{@project.id}/event_exports",
         params: { start_date: "2026-01-01", end_date: "2026-04-03" }, headers: @admin, as: :json
    assert_response :unprocessable_entity, "93 inclusive days is past the documented 92"
  end
end
