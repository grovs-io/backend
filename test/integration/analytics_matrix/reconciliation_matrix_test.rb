# frozen_string_literal: true

require "test_helper"
require_relative "../auth_test_helper"
require_relative "scenario_dsl"
require_relative "matrix_generator"

# Pass A: each scenario's PG Event row and CH events row reconcile. One isolated
# test method per scenario (clean Redis + CH) so VIEW dedup can't drop rows.
class ReconciliationMatrixTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include ClickhouseTestHelper
  include AnalyticsMatrix::ScenarioDSL

  fixtures :instances, :projects, :applications, :ios_configurations,
           :android_configurations, :web_configurations,
           :web_configuration_linked_domains, :devices, :visitors, :domains,
           :redirect_configs, :campaigns, :links

  WEB_IDENTIFIER = "app.example.com"

  # SDK-reachable slice: with_visitor, configured platforms, all attributions.
  # unknown platform + without_visitor are process_batch-only (Phase 4).
  PLATFORMS_READY    = %w[ios android web].freeze
  ATTRIBUTIONS_READY = %i[no_link plain_link campaign_link inviter_link].freeze

  SCENARIOS = AnalyticsMatrix::MatrixGenerator.new(project: :one).scenarios.select do |s|
    s.visitor == :with_visitor &&
      PLATFORMS_READY.include?(s.platform) &&
      ATTRIBUTIONS_READY.include?(s.attribution)
  end

  setup do
    matrix_setup!
    @project  = projects(:one)
    @domain   = domains(:one)
    @redirect = redirect_configs(:one)

    # Specialized records are created at RUNTIME (rolled back per test), never as
    # global YAML fixtures: adding rows/flags to shared fixtures changed counts
    # and broke explicit preconditions elsewhere ("web_device has no visitor",
    # "no SDK links in fixtures", pagination counts).
    @web_visitor      = build_visitor(devices(:web_device), web: true, tag: "web")
    @referrer_device  = build_device("referrer")
    @referrer_visitor = build_visitor(@referrer_device, tag: "referrer")
    @inviter_link     = Link.create!(
      domain: @domain, redirect_config: @redirect, path: "mtx-inviter-path",
      title: "Inviter Link", generated_from_platform: "ios", active: true,
      sdk_generated: true, visitor: @referrer_visitor
    )
    links(:campaign_link).update!(campaign: campaigns(:one)) # campaign_link is a pristine fixture

    register_matrix_world(
      project: @project,
      devices_by_platform: {
        "ios"     => world_device(devices(:ios_device), visitors(:ios_visitor), "ios"),
        "android" => world_device(devices(:android_device), visitors(:android_visitor), "android"),
        "web"     => world_device(devices(:web_device), @web_visitor, "web", identifier: WEB_IDENTIFIER)
      },
      links_by_attribution: {
        no_link:       nil,
        plain_link:    links(:basic_link),
        campaign_link: links(:campaign_link),
        inviter_link:  @inviter_link
      }
    )
  end

  teardown { matrix_teardown! }

  SCENARIOS.each do |scn|
    define_method("test_reconcile_#{scn.platform}_#{scn.event}_#{scn.attribution}_#{scn.token}") do
      ingest_via_http([scn])
      assert_reconciles(scn)
    end
  end

  # The matrix asserts inviter_id: 0 (installers start uninvited). This covers the
  # complementary path: an event from an ALREADY-invited visitor carries that
  # inviter_id into the CH row (visitor loaded with inviter_id set at batch start).
  test "ch inviter_id reflects an already-invited visitor" do
    invited_device  = build_device("invited")
    invited_visitor = build_visitor(invited_device, tag: "invited")
    invited_visitor.update!(inviter: @referrer_visitor)

    post "#{AuthTestHelper::SDK_PREFIX}/events/batch",
         params: { events: [{ event: Grovs::Events::OPEN, session_id: "inv-tok" }] },
         headers: sdk_headers_for(@project, invited_visitor, platform: "ios")
    assert_response :ok
    drain_event_queue!

    ch = ch_rows_for("inv-tok", @project.id).first
    assert_not_nil ch, "expected a CH row for the invited visitor's event"
    assert_equal @referrer_visitor.id, ch["inviter_id"].to_i
  end

  # Custom-event properties must round-trip: PG Event.data <-> CH events.properties.
  # The matrix sends no properties, so this path is otherwise unexercised.
  test "custom event properties reconcile into PG data and CH properties" do
    headers = sdk_headers_for(@project, visitors(:ios_visitor), platform: "ios")
    props = { "plan" => "premium", "level" => "7" }

    post "#{AuthTestHelper::SDK_PREFIX}/events/batch",
         params: { events: [{ event_name: "mtx_props", session_id: "props-tok", properties: props }] },
         headers: headers
    assert_response :ok
    drain_event_queue!

    pg = Event.find_by!(session_id: "props-tok")
    assert_equal Grovs::Events::CUSTOM, pg.event
    assert_equal props, pg.data

    ch = ch_rows_for("props-tok", @project.id).first
    assert_not_nil ch, "expected a CH row for the custom-properties event"
    assert_equal props, ch["properties"]
  end

  # process_batch-driven reconciliation for cells the SDK endpoint can't reach
  # (no LINKSQUARED visitor / no configured app). These are Pass A concerns, so
  # they live here rather than waiting for the high-volume phase.
  test "process_batch parks a visitorless device event to the integrity DLQ" do
    novisitor = build_device("novisitor") # created without any Visitor row

    ingest_via_process_batch([raw_event(device: novisitor, type: "open", session_id: "pb-nov")])

    assert_equal 0, Event.where(session_id: "pb-nov").count, "parked payload must not insert to PG"
    assert_equal 0, ch_rows_for("pb-nov", @project.id).size, "parked payload must not reach CH"
    parked = REDIS.with { |conn| conn.lrange(BatchEventProcessorJob::INTEGRITY_DLQ_KEY, 0, -1) }
      .map { |raw| JSON.parse(raw, symbolize_names: true) }
    assert_equal [novisitor.id], parked.map { |p| p[:device_id] }
  end

  test "process_batch reconciles an unknown-platform event" do
    unknown = build_device("unknown", platform: "unknown")
    visitor = build_visitor(unknown, tag: "unknown")
    assert visitor.persisted?

    ingest_via_process_batch([raw_event(device: unknown, type: "open", session_id: "pb-unk")])

    pg = Event.where(session_id: "pb-unk")
    assert_equal 1, pg.count
    assert_equal "unknown", pg.first.platform
    ch = ch_rows_for("pb-unk", @project.id)
    assert_equal 1, ch.size
    assert_equal "unknown", ch.first["platform"].to_s
  end

  private

  def world_device(device, visitor, platform, identifier: nil)
    {
      device:  device,
      visitor: visitor,
      headers: sdk_headers_for(@project, visitor, platform: platform, identifier: identifier)
    }
  end

  def build_device(tag, platform: "ios")
    Device.create!(
      user_agent: "TestApp/1.0 #{tag}", ip: "192.168.9.9", remote_ip: "10.0.9.9",
      platform: platform, vendor: "mtx-#{tag}-#{SecureRandom.hex(4)}",
      model: "iPhone 14", app_version: "1.5.0", build: "1"
    )
  end

  # Raw Redis-payload JSON for the process_batch path (bypasses SDK auth/visitor
  # requirement), matching parse_events' expected keys.
  def raw_event(device:, type:, session_id:, link: nil)
    {
      type: type, project_id: @project.id, device_id: device.id, link_id: link&.id,
      data: nil, engagement_time: nil, created_at: Time.current.iso8601(3),
      event_name: "", session_id: session_id, tags: []
    }.to_json
  end

  def build_visitor(device, tag:, web: false)
    Visitor.create!(
      project: @project, device: device, web_visitor: web,
      sdk_identifier: "mtx_#{tag}", uuid: SecureRandom.uuid
    )
  end
end
