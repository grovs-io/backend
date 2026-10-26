require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class EventStreamApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include ClickhouseTestHelper
  include EventStreamTestHelper
  fixtures :instances, :users, :instance_roles, :projects, :devices, :visitors

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @admin = doorkeeper_headers_for(users(:admin_user))
    entitle!(instances(:one))
    @seeded_at = 10.minutes.ago.change(usec: 0)
    insert_outbox_events((1..3).map do |i|
      { project_id: @project.id, event_type: "install", outbox_at: @seeded_at + i, event_id: "e#{i}",
        device_id: devices(:ios_device).id, visitor_id: visitors(:ios_visitor).id }
    end)
  end

  def base = "#{API_PREFIX}/projects/#{@project.id}"
  def token_headers(plain) = { "Authorization" => "Bearer #{plain}", "Host" => api_host }

  test "admin creates a token; the token reads the feed with a cursor" do
    post "#{base}/event_stream_tokens", params: { name: "warehouse" }, headers: @admin, as: :json
    assert_response :created
    plain = JSON.parse(response.body)["token"]
    assert_match(/\Aest_/, plain)

    get "#{base}/event_stream", params: { limit: 2 }, headers: token_headers(plain)
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal 1, body["schema_version"]
    assert_equal %w[e1 e2], body["events"].map { |e| e["id"] }
    cursor = body["next_after"]
    assert cursor.present?

    get "#{base}/event_stream", params: { limit: 10, after: cursor }, headers: token_headers(plain)
    assert_equal %w[e3], JSON.parse(response.body)["events"].map { |e| e["id"] }
  end

  test "a token name over 255 characters is refused with the validation message, and nothing is created" do
    assert_no_difference("EventStreamToken.count") do
      post "#{base}/event_stream_tokens", params: { name: "x" * 256 }, headers: @admin, as: :json
    end
    assert_response :unprocessable_entity
    assert_equal({ "error" => "Name is too long (maximum is 255 characters)" }, response.parsed_body)
  end

  test "doorkeeper member can read the feed, unentitled instance cannot, foreign token cannot" do
    get "#{base}/event_stream", headers: doorkeeper_headers_for(users(:member_user))
    assert_response :ok

    post "#{base}/event_stream_tokens", params: { name: "t" }, headers: @admin, as: :json
    plain = JSON.parse(response.body)["token"]
    get "#{API_PREFIX}/projects/#{projects(:two).id}/event_stream", headers: token_headers(plain)
    assert_response :forbidden

    unentitle!(instances(:one))
    get "#{base}/event_stream", headers: @admin
    assert_response :payment_required
  end

  test "revoked token is rejected; list and destroy" do
    post "#{base}/event_stream_tokens", params: { name: "t" }, headers: @admin, as: :json
    body = JSON.parse(response.body)
    get "#{base}/event_stream_tokens", headers: @admin
    assert_equal 1, JSON.parse(response.body)["event_stream_tokens"].size
    delete "#{base}/event_stream_tokens/#{body['event_stream_token']['id']}", headers: @admin
    assert_response :ok
    get "#{base}/event_stream", headers: token_headers(body["token"])
    assert_response :unauthorized
  end

  test "revoking a token purges the outbox only after the revoke commits" do
    post "#{base}/event_stream_tokens", params: { name: "t" }, headers: @admin, as: :json
    id = JSON.parse(response.body)["event_stream_token"]["id"]
    outside = ActiveRecord::Base.connection.open_transactions
    depth = nil
    EventStream::Outbox.stub(:sync_project!, ->(_project) { depth = ActiveRecord::Base.connection.open_transactions }) do
      delete "#{base}/event_stream_tokens/#{id}", headers: @admin
    end
    assert_response :ok
    assert_equal outside, depth
  end

  test "a pull-only project captures only while it holds an active token" do
    assert_not_includes EventStream::Outbox.enabled_project_ids, @project.id

    post "#{base}/event_stream_tokens", params: { name: "pull" }, headers: @admin, as: :json
    assert_includes EventStream::Outbox.enabled_project_ids, @project.id

    delete "#{base}/event_stream_tokens/#{JSON.parse(response.body)['event_stream_token']['id']}", headers: @admin
    assert_not_includes EventStream::Outbox.enabled_project_ids, @project.id
  end

  test "limit caps analytics and purchases together, in arrival order" do
    insert_outbox_purchases([{ project_id: @project.id, event_type: "buy", transaction_id: "p1", device_id: devices(:ios_device).id,
                               visitor_id: visitors(:ios_visitor).id, outbox_at: @seeded_at + 1.5 }])
    get "#{base}/event_stream", params: { limit: 2 }, headers: @admin
    first = JSON.parse(response.body)
    assert_equal %w[install purchase], first["events"].map { |e| e["type"] }

    get "#{base}/event_stream", params: { limit: 2, after: first["next_after"] }, headers: @admin
    assert_equal %w[e2 e3], JSON.parse(response.body)["events"].map { |e| e["id"] }
  end

  test "a busy poller does not write last_used_at on every read" do
    post "#{base}/event_stream_tokens", params: { name: "pull" }, headers: @admin, as: :json
    plain = JSON.parse(response.body)["token"]
    get "#{base}/event_stream", headers: token_headers(plain)
    first = EventStreamToken.order(:id).last.last_used_at
    get "#{base}/event_stream", headers: token_headers(plain)
    assert_equal first, EventStreamToken.order(:id).last.last_used_at
  end

  test "structurally invalid cursors are a 400, not a 500" do
    ["null", '{"e":[1,2],"p":[null,""]}', '{"e":"x","p":[null,""]}', '{"e":["not a time",""],"p":[null,""]}'].each do |json|
      get "#{base}/event_stream", params: { after: Base64.urlsafe_encode64(json, padding: false) }, headers: @admin
      assert_response :bad_request, json
    end
  end

  test "bad cursor is a 400" do
    get "#{base}/event_stream", params: { after: "!!!" }, headers: @admin
    assert_response :bad_request
  end
end
