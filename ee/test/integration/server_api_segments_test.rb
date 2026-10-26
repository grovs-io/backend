require "test_helper"
require "sidekiq/testing"
require_relative "../../../test/integration/auth_test_helper"

class ServerApiSegmentsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include ClickhouseTestHelper

  fixtures :instances, :users, :instance_roles, :projects

  BASE = "#{SDK_PREFIX}/server/segments".freeze

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @instance = @project.instance
    entitle!(@instance)
    entitle!(projects(:two).instance)
    @headers = server_sdk_headers_for(@project)
    clear_redis
    insert_ch_events([ev(1, "checkout"), ev(2, "checkout"), ev(3, "signup")])
  end

  teardown { clear_redis if @project } # setup may skip before @project is set

  def clear_redis
    keys = %i[dashboard server].flat_map do |lane|
      cfg = Segments::Permits::LANES.fetch(lane)
      [cfg[:global_key], Segments::Permits.project_key(@project.id, lane: lane)]
    end
    REDIS.with do |c|
      c.del(*keys, "audit:api_key_used:#{@instance.id}:127.0.0.1", "audit:api_key_failed:#{@instance.id}:127.0.0.1")
      c.keys("segments:result*").each { |k| c.del(k) }
      c.keys("segments:identifier_upload:*").each { |k| c.del(k) }
    end
  end

  def ev(visitor, name)
    { project_id: @project.id, visitor_id: visitor, device_id: visitor, event_type: "custom", event_name: name,
      country: "RO", platform: "ios", created_at: (Time.now.utc - 2.days).strftime("%Y-%m-%d %H:%M:%S.000") }
  end

  def definition(event_name = "checkout", days = 30)
    { version: 1, operator: "or", groups: [{ operator: "and", conditions: [
      { type: "event", event_name: event_name, window: { last_days: days } }
    ] }] }
  end

  def body = response.parsed_body
  def ch_on(&) = Clickhouse.stub(:read_enabled?, true) { Clickhouse.stub(:enabled?, true, &) }

  def create_segment(name: "Buyers", headers: @headers, **extra)
    post BASE, params: { name: name, definition: definition }.merge(extra), headers: headers, as: :json
    assert_response :created
    body["segment"]["id"]
  end

  def fill_lane(lane)
    key = Segments::Permits.project_key(@project.id, lane: lane)
    limit = Segments::Permits.const_get(Segments::Permits::LANES.fetch(lane)[:limits].last)
    REDIS.with { |c| limit.times { |i| c.zadd(key, Time.now.to_f + 60, "held-#{i}") } }
  end

  test "missing key is 400, wrong key 403, bad ENVIRONMENT 400" do
    get BASE, headers: @headers.except("PROJECT-KEY")
    assert_response :bad_request
    assert_match(/PROJECT-KEY/, body["error"])

    get BASE, headers: @headers.merge("PROJECT-KEY" => "nope")
    assert_response :forbidden
    assert_equal "Invalid credentials", body["error"]

    get BASE, headers: @headers.merge("ENVIRONMENT" => "staging")
    assert_response :bad_request
    assert_match(/ENVIRONMENT/, body["error"])
  end

  test "the test environment and the production one never see each other's segments" do
    prod = create_segment(name: "Prod")
    test_headers = server_sdk_headers_for(@project, environment: "test")
    test_id = create_segment(name: "Test", headers: test_headers)

    get "#{BASE}/#{prod}", headers: test_headers
    assert_response :not_found
    get "#{BASE}/#{test_id}", headers: @headers
    assert_response :not_found
    get BASE, headers: test_headers
    assert_equal ["Test"], body["segments"].map { |s| s["name"] }
    assert_equal projects(:one_test).id, Segment.find_by_hashid(test_id).project_id
  end

  test "another instance's key cannot read or change this instance's segments" do
    id = create_segment
    other = server_sdk_headers_for(projects(:two))
    get "#{BASE}/#{id}", headers: other
    assert_response :not_found
    patch "#{BASE}/#{id}", params: { name: "Taken" }, headers: other, as: :json
    assert_response :not_found
    delete "#{BASE}/#{id}", headers: other
    assert_response :not_found
    assert_equal "Buyers", Segment.find_by_hashid(id).name
  end

  test "an instance without a paid plan is refused with enterprise_required" do
    unentitle!(@instance)
    StripeSubscription.where(instance: @instance).update_all(active: false)
    get BASE, headers: @headers
    assert_response :forbidden
    assert_equal "enterprise_required", body["error_code"]
    post BASE, params: { name: "x", definition: definition }, headers: @headers, as: :json
    assert_response :forbidden
    assert_equal 0, Segment.count
  end

  test "index, fields, estimate, create, show, update and destroy" do
    ch_on do
      get "#{BASE}/fields", headers: @headers
      assert_response :ok
      assert body.key?("conditions")

      post "#{BASE}/estimate", params: { definition: definition }, headers: @headers, as: :json
      assert_response :ok
      assert_equal 2, body["persons"]

      id = create_segment
      assert_equal "Buyers", body["segment"]["name"]

      get BASE, headers: @headers
      assert_response :ok
      assert_equal ["Buyers"], body["segments"].map { |s| s["name"] }

      get "#{BASE}/#{id}", headers: @headers
      assert_response :ok
      assert_equal id, body["segment"]["id"]

      patch "#{BASE}/#{id}", params: { name: "Signups", definition: definition("signup") }, headers: @headers, as: :json
      assert_response :ok
      assert_equal "Signups", body["segment"]["name"]

      delete "#{BASE}/#{id}", headers: @headers
      assert_response :ok
      assert Segment.find_by_hashid(id).archived
      get BASE, headers: @headers
      assert_empty body["segments"]
    end
  end

  test "an invalid definition is 422" do
    post BASE, params: { name: "Bad", definition: "nope" }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    post BASE, params: { name: "Bad", definition: { version: 1, operator: "or", groups: [{ operator: "and", conditions: [{ type: "bogus" }] }] } },
               headers: @headers, as: :json
    assert_response :unprocessable_entity
    ch_on { post "#{BASE}/estimate", params: { definition: { version: 1, operator: "or", groups: [] } }, headers: @headers, as: :json }
    assert_response :unprocessable_entity
    assert_equal 0, Segment.count
  end

  test "count runs on ClickHouse" do
    id = create_segment
    ch_on { post "#{BASE}/#{id}/count", headers: @headers, as: :json }
    assert_response :ok
    assert_equal [2, 2], body.values_at("persons", "devices")
    assert body["result_id"].present?
  end

  test "identifier_list stores the list in ClickHouse and refuses one over the limit" do
    id = create_segment
    ch_on { post "#{BASE}/#{id}/identifier_list", params: { identifiers: ["a@x.io", "b@x.io", "a@x.io"] }, headers: @headers, as: :json }
    assert_response :ok
    assert_equal 2, body["count"]
    assert body["segment"]["has_identifier_list"]
    segment = Segment.find_by_hashid(id)
    stored = Clickhouse.with { |c| c.select_value("SELECT count() FROM segment_identifier_entries WHERE segment_id = #{segment.id}") }
    assert_equal 2, stored.to_i

    too_many = Array.new(Segments::IdentifierList::MAX_ENTRIES + 1) { |i| "u#{i}" }
    ch_on { post "#{BASE}/#{id}/identifier_list", params: { identifiers: too_many }, headers: @headers, as: :json }
    assert_response :unprocessable_entity
    assert_match(/between 1 and/, body["error"])
    assert_equal 2, segment.reload.identifier_list_count
  end

  test "writes are audited as the api key and leave created_by empty" do
    id = create_segment
    patch "#{BASE}/#{id}", params: { name: "Renamed" }, headers: @headers, as: :json
    delete "#{BASE}/#{id}", headers: @headers
    %w[segment.created segment.updated segment.archived].each do |action|
      event = AuditEvent.find_by(instance_id: @instance.id, action: action)
      assert event, action
      assert_equal "api_key", event.actor["type"], action
    end
    assert_nil Segment.find_by_hashid(id).created_by_id
    used = AuditEvent.where(instance_id: @instance.id, action: "api_key.used")
    assert_equal 1, used.count
    assert_equal "127.0.0.1", used.first.ip
    assert used.first.request_id.present?
  end

  test "a known key with bad credentials is audited as auth_failed once per day" do
    2.times { get BASE, headers: @headers.merge("ENVIRONMENT" => "staging") }
    assert_response :bad_request
    assert_equal 1, AuditEvent.where(instance_id: @instance.id, action: "api_key.auth_failed").count
  end

  test "end-user data and dashboard-only actions are not routed" do
    id = create_segment
    post "#{BASE}/#{id}/users", headers: @headers, as: :json
    assert_response :not_found
    post "#{BASE}/#{id}/export", headers: @headers, as: :json
    assert_response :not_found
    post "#{BASE}/#{id}/breakdown", params: { by: "country" }, headers: @headers, as: :json
    assert_response :not_found
    get "#{BASE}/#{id}/size_history", headers: @headers
    assert_response :not_found
    assert_equal 0, SegmentExport.count
  end

  test "server counts use their own permit lane, apart from the dashboard's" do
    first = create_segment(name: "A")
    second = create_segment(name: "B", definition: definition("signup"))
    dashboard = doorkeeper_headers_for(users(:member_user))

    ch_on do
      fill_lane(:dashboard)
      post "#{API_PREFIX}/projects/#{@project.id}/segments/#{first}/count", headers: dashboard, as: :json
      assert_response :too_many_requests
      post "#{BASE}/#{first}/count", headers: @headers, as: :json
      assert_response :ok, "a full dashboard lane does not block the server lane"

      clear_redis
      fill_lane(:server)
      post "#{BASE}/#{second}/count", headers: @headers, as: :json
      assert_response :too_many_requests
      assert_equal "segment_busy", body["error_code"]

      post "#{API_PREFIX}/projects/#{@project.id}/segments/#{second}/count", headers: dashboard, as: :json
      assert_response :ok, "a full server lane leaves the dashboard lane alone"
    end
  end
end
