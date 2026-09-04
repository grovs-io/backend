# frozen_string_literal: true

require 'test_helper'

class ClickhouseEventRowBuilderTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs, :campaigns

  Profile = Struct.new(:sdk_attributes)

  setup do
    @row_builder = ClickhouseEventRowBuilder.new
    @project = projects(:one)
    @device = devices(:ios_device)
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)
  end

  test 'resolve: screen_view gets the real name from properties, not the literal event_name' do
    row = { event_name: 'screen_view', event: 'screen_view', project_id: @project.id,
            data: { 'screen_name' => 'Grovs Store' } }
    assert_equal 'Grovs Store', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: properties screen_name works with symbol keys (batch path)' do
    row = { event_name: 'screen_view', event: 'screen_view', project_id: @project.id,
            data: { screen_name: 'BatchStore' } }
    assert_equal 'BatchStore', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: properties screen_name is alias-mapped when a matching ScreenAlias exists' do
    ScreenAlias.create!(project: @project, screen_identifier: '/checkout', alias_name: 'Checkout')

    row = { event_name: 'screen_view', event: 'screen_view', project_id: @project.id,
            data: { 'screen_name' => '/checkout' } }
    assert_equal 'Checkout', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: properties screen_name beats visitor sdk_attributes' do
    row = { event_name: 'screen_view', event: 'screen_view', project_id: @project.id,
            data: { 'screen_name' => 'PerEventScreen' } }
    assert_equal 'PerEventScreen', @row_builder.resolve_screen_name(row, Profile.new({ 'screen_name' => 'StaleVisitorScreen' }))
  end

  test 'resolve: custom event gets the screen it occurred on from properties' do
    row = { event_name: 'add_to_cart', event: 'custom', project_id: @project.id,
            data: { 'screen_name' => 'Product Page' } }
    assert_equal 'Product Page', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: blank properties screen_name falls through to event_name' do
    row = { event_name: 'MyScreen', event: 'screen_view', project_id: @project.id,
            data: { 'screen_name' => '' } }
    assert_equal 'MyScreen', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: string JSON data with screen_name is honored' do
    row = { event_name: 'screen_view', event: 'screen_view', project_id: @project.id,
            data: '{"screen_name":"JsonScreen"}' }
    assert_equal 'JsonScreen', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: non-Hash JSON data does not crash and falls back to event_name' do
    row = { event_name: 'screen_view', event: 'screen_view', project_id: @project.id, data: '[1,2]' }
    assert_equal 'screen_view', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: properties screen_name is capped at 255 chars' do
    row = { event_name: 'screen_view', event: 'screen_view', project_id: @project.id,
            data: { 'screen_name' => 'S' * 8_000 } }
    assert_equal 'S' * 255, @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: properties screen_name is stripped before the alias lookup' do
    ScreenAlias.create!(project: @project, screen_identifier: '/checkout', alias_name: 'Checkout')

    row = { event_name: 'screen_view', event: 'screen_view', project_id: @project.id,
            data: { 'screen_name' => '  /checkout  ' } }
    assert_equal 'Checkout', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: non-scalar properties screen_name is ignored' do
    row = { event_name: 'screen_view', event: 'screen_view', project_id: @project.id,
            data: { 'screen_name' => { 'a' => 1 } } }
    assert_equal 'screen_view', @row_builder.resolve_screen_name(row, Profile.new(nil))

    row[:data] = { 'screen_name' => false }
    assert_equal 'screen_view', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: properties screen_name suppresses the event_name alias' do
    ScreenAlias.create!(project: @project, screen_identifier: 'screen_view', alias_name: 'WrongAlias')

    row = { event_name: 'screen_view', event: 'screen_view', project_id: @project.id,
            data: { 'screen_name' => 'RealScreen' } }
    assert_equal 'RealScreen', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: visitor sdk_attributes screen_name is alias-mapped too' do
    ScreenAlias.create!(project: @project, screen_identifier: '/home', alias_name: 'Home')

    row = { event_name: 'screen_view', event: 'screen_view', project_id: @project.id }
    assert_equal 'Home', @row_builder.resolve_screen_name(row, Profile.new({ 'screen_name' => '/home' }))
  end

  test 'resolve: returns screen_name from Hash event data' do
    row = { event_name: 'something', event: 'VIEW', project_id: @project.id }
    assert_equal 'HomeScreen', @row_builder.resolve_screen_name(row, Profile.new({ 'screen_name' => 'HomeScreen' }))
  end

  # parse_events symbolizes recursively, so the batch path hands us { screen_name: ... }.
  test 'resolve: returns screen_name from symbol-keyed event data' do
    row = { event_name: 'ignored', event: 'VIEW', project_id: @project.id }
    assert_equal 'BatchScreen', @row_builder.resolve_screen_name(row, Profile.new({ screen_name: 'BatchScreen' }))
  end

  test 'resolve: Hash event data takes priority over event_name' do
    row = { event_name: 'EventScreen', event: 'VIEW', project_id: @project.id }
    assert_equal 'SDKScreen', @row_builder.resolve_screen_name(row, Profile.new({ 'screen_name' => 'SDKScreen' }))
  end

  test 'resolve: skips Hash event data when screen_name is blank' do
    row = { event_name: 'FallbackScreen', event: 'screen_view', project_id: @project.id }
    assert_equal 'FallbackScreen', @row_builder.resolve_screen_name(row, Profile.new({ 'screen_name' => '' }))
  end

  test 'resolve: skips Hash event data when screen_name key is missing' do
    row = { event_name: 'SomeEvent', event: 'screen_view', project_id: @project.id }
    assert_equal 'SomeEvent', @row_builder.resolve_screen_name(row, Profile.new({ 'other_key' => 'value' }))
  end

  test 'resolve: returns screen_name from String JSON event data' do
    row = { event_name: 'event', event: 'VIEW', project_id: @project.id }
    assert_equal 'ProfileScreen', @row_builder.resolve_screen_name(row, Profile.new('{"screen_name":"ProfileScreen"}'))
  end

  test 'resolve: skips malformed JSON string attrs gracefully' do
    row = { event_name: 'MyEvent', event: 'screen_view', project_id: @project.id }
    assert_equal 'MyEvent', @row_builder.resolve_screen_name(row, Profile.new('not json {{{'))
  end

  test 'resolve: skips String JSON when screen_name is blank' do
    row = { event_name: 'FallbackEvent', event: 'custom', project_id: @project.id }
    assert_equal 'FallbackEvent', @row_builder.resolve_screen_name(row, Profile.new('{"screen_name":""}'))
  end

  test 'resolve: returns alias_name from ScreenAlias when event_name matches' do
    ScreenAlias.create!(project: @project, screen_identifier: 'raw_event_name', alias_name: 'AliasedScreen')

    row = { event_name: 'raw_event_name', event: 'OTHER', project_id: @project.id }
    assert_equal 'AliasedScreen', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: ScreenAlias takes priority over event_name fallback' do
    ScreenAlias.create!(project: @project, screen_identifier: 'my_event', alias_name: 'MappedScreen')

    row = { event_name: 'my_event', event: 'screen_view', project_id: @project.id }
    assert_equal 'MappedScreen', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: ScreenAlias does not match across projects' do
    other_project = projects(:two)
    ScreenAlias.create!(project: other_project, screen_identifier: 'shared_name', alias_name: 'OtherProjectAlias')

    row = { event_name: 'shared_name', event: 'screen_view', project_id: @project.id }
    # No alias for @project, falls back to event_name for screen_view
    assert_equal 'shared_name', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: returns event_name for screen_view event type' do
    row = { event_name: 'ScreenViewEvent', event: 'screen_view', project_id: @project.id }
    assert_equal 'ScreenViewEvent', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: returns event_name for custom event type' do
    row = { event_name: 'CustomEvent', event: 'custom', project_id: @project.id }
    assert_equal 'CustomEvent', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: returns empty string for VIEW event type without screen metadata' do
    row = { event_name: 'PageView', event: 'VIEW', project_id: @project.id }
    assert_equal '', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: returns empty string for OPEN event type without screen metadata' do
    row = { event_name: 'AppOpen', event: 'OPEN', project_id: @project.id }
    assert_equal '', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: returns empty string for non-screen event type with no aliases' do
    row = { event_name: 'SomeEvent', event: 'INSTALL', project_id: @project.id }
    assert_equal '', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: returns empty string when everything is nil/blank' do
    row = { event_name: '', event: '', project_id: @project.id }
    assert_equal '', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'resolve: returns empty string when event_name nil and non-screen event type' do
    row = { event_name: nil, event: 'TIME_SPENT', project_id: @project.id }
    assert_equal '', @row_builder.resolve_screen_name(row, Profile.new(nil))
  end

  test 'screen_aliases_for_project: caches across calls for same project' do
    ScreenAlias.create!(project: @project, screen_identifier: 'evt1', alias_name: 'Screen1')

    result1 = @row_builder.send(:screen_aliases_for_project, @project.id)
    assert_equal({ 'evt1' => 'Screen1' }, result1)

    # Add another alias — cache should NOT re-query
    ScreenAlias.create!(project: @project, screen_identifier: 'evt2', alias_name: 'Screen2')
    result2 = @row_builder.send(:screen_aliases_for_project, @project.id)
    assert_equal({ 'evt1' => 'Screen1' }, result2, 'should return cached result, not re-query')
  end

  test 'screen_aliases_for_project: different projects get separate caches' do
    other_project = projects(:two)
    ScreenAlias.create!(project: @project, screen_identifier: 'a', alias_name: 'AliasA')
    ScreenAlias.create!(project: other_project, screen_identifier: 'b', alias_name: 'AliasB')

    result_one = @row_builder.send(:screen_aliases_for_project, @project.id)
    result_two = @row_builder.send(:screen_aliases_for_project, other_project.id)

    assert_equal({ 'a' => 'AliasA' }, result_one)
    assert_equal({ 'b' => 'AliasB' }, result_two)
  end

  test 'screen_aliases_for_project: returns empty hash when no aliases exist' do
    result = @row_builder.send(:screen_aliases_for_project, @project.id)
    assert_equal({}, result)
  end

  test "build_clickhouse_row uses frozen ch_meta source over the link current state" do
    # Link drifted post-ingest (a later merge repointed it to a different visitor/campaign).
    @link.update_columns(campaign_id: campaigns(:one).id, visitor_id: @visitor.id)
    pg_row = {
      project_id: @project.id, event: Grovs::Events::OPEN, device_id: @device.id,
      link_id: @link.id, created_at: Time.current, event_name: "", session_id: "",
      engagement_time: 0, data: nil, ip: "", remote_ip: "", platform: "ios",
      app_version: "", build: "", vendor_id: "", path: "",
      ch_meta: { event_id: "frozen-eid", campaign_id: 55, sdk_generated: true, link_visitor_id: 67890 }
    }

    row = @row_builder.build_row(pg_row, @device, @visitor, @link)

    assert_equal "frozen-eid", row[:event_id]
    assert_equal 55, row[:campaign_id]
    assert_equal 1, row[:sdk_generated]
    assert_equal 67890, row[:link_visitor_id]
  end

  # A negative value would fail the UInt64 parse in CH and poison the whole insert batch.
  test "build_clickhouse_row clamps negative engagement_time to zero" do
    pg_row = {
      project_id: @project.id, event: Grovs::Events::TIME_SPENT, device_id: @device.id,
      link_id: nil, created_at: Time.current, event_name: "", session_id: "",
      engagement_time: -300, data: nil, ip: "", remote_ip: "", platform: "ios",
      app_version: "", build: "", vendor_id: "", path: ""
    }

    row = @row_builder.build_row(pg_row, @device, @visitor, nil)

    assert_equal 0, row[:engagement_time]
    expected_eid = ClickhouseWriteService.generate_event_id(
      project_id: @project.id, device_id: @device.id, event_type: Grovs::Events::TIME_SPENT,
      created_at: pg_row[:created_at], event_name: "", session_id: "", engagement_time: 0
    )
    assert_equal expected_eid, row[:event_id], "event_id must hash the clamped value"
  end

  test "build_clickhouse_row falls back to the link when ch_meta is absent (pre-deploy payload)" do
    @link.update_columns(campaign_id: campaigns(:one).id, visitor_id: @visitor.id, sdk_generated: true)
    pg_row = {
      project_id: @project.id, event: Grovs::Events::OPEN, device_id: @device.id,
      link_id: @link.id, created_at: Time.current, event_name: "", session_id: "",
      engagement_time: 0, data: nil, ip: "", remote_ip: "", platform: "ios",
      app_version: "", build: "", vendor_id: "", path: ""
    }

    row = @row_builder.build_row(pg_row, @device, @visitor, @link.reload)

    assert_equal campaigns(:one).id, row[:campaign_id]
    assert_equal 1, row[:sdk_generated]
    assert_equal @visitor.id, row[:link_visitor_id]
    assert_equal 32, row[:event_id].to_s.length, "event_id recomputed when not frozen"
  end

  test "frozen event_id is used even when the device differs from ingest (merge remap)" do
    other_device = devices(:android_device)
    frozen_eid = ClickhouseWriteService.generate_event_id(
      project_id: @project.id, device_id: @device.id, event_type: Grovs::Events::OPEN,
      created_at: Time.current, event_name: "", session_id: "", link_id: 0
    )
    pg_row = {
      project_id: @project.id, event: Grovs::Events::OPEN, device_id: other_device.id,
      link_id: 0, created_at: Time.current, event_name: "", session_id: "",
      engagement_time: 0, data: nil, ip: "", remote_ip: "", platform: "android",
      app_version: "", build: "", vendor_id: "", path: "",
      ch_meta: { event_id: frozen_eid, campaign_id: nil, sdk_generated: false, link_visitor_id: 0 }
    }

    # Built with other_device (the merge survivor), but the frozen id must win.
    row = @row_builder.build_row(pg_row, other_device, @visitor, nil)
    assert_equal frozen_eid, row[:event_id]

    # Prove freezing matters: recomputing with the survivor device yields a DIFFERENT id.
    recomputed = ClickhouseWriteService.generate_event_id(
      project_id: @project.id, device_id: other_device.id, event_type: Grovs::Events::OPEN,
      created_at: pg_row[:created_at], event_name: "", session_id: "", link_id: 0
    )
    assert_not_equal recomputed, frozen_eid
  end

  test "frozen-nil source wins over the link (does not fall back when key present)" do
    # ch_meta froze the event as organic (nil), even though the link later carries a campaign.
    @link.update_columns(campaign_id: campaigns(:one).id, visitor_id: @visitor.id, sdk_generated: true)
    pg_row = {
      project_id: @project.id, event: Grovs::Events::OPEN, device_id: @device.id,
      link_id: @link.id, created_at: Time.current, event_name: "", session_id: "",
      engagement_time: 0, data: nil, ip: "", remote_ip: "", platform: "ios",
      app_version: "", build: "", vendor_id: "", path: "",
      ch_meta: { event_id: "eid", campaign_id: nil, sdk_generated: false, link_visitor_id: nil }
    }

    row = @row_builder.build_row(pg_row, @device, @visitor, @link.reload)
    assert_equal 0, row[:campaign_id], "frozen nil must not fall back to the link's campaign"
    assert_equal 0, row[:sdk_generated]
    assert_equal 0, row[:link_visitor_id]
  end

  test "build_clickhouse_row fills screen_name from properties for a screen_view" do
    pg_row = {
      project_id: @project.id, device_id: @device.id, event: Grovs::Events::SCREEN_VIEW,
      event_name: "screen_view", session_id: "sess-1", link_id: nil, platform: "web",
      app_version: "2.0", build: "2.0", vendor_id: @device.vendor, engagement_time: 0,
      data: { "manual" => true, "screen_name" => "Manual Screen" },
      tags: [], ip: "1.1.1.1", remote_ip: "1.1.1.1", path: "", created_at: Time.current
    }

    row = GeoipService.stub(:lookup, { country: "", city: "" }) do
      @row_builder.build_row(pg_row, @device, @visitor, nil)
    end

    assert_equal "Manual Screen", row[:screen_name]
    assert_equal "screen_view", row[:event_name]
  end

  test "ensure_hash passes through a Hash unchanged" do
    h = { "plan" => "premium", "age" => 25 }
    assert_equal h, @row_builder.ensure_hash(h)
  end

  test "ensure_hash parses a valid JSON string into a Hash" do
    assert_equal({ "plan" => "free" }, @row_builder.ensure_hash('{"plan": "free"}'))
  end

  test "ensure_hash returns empty hash for invalid JSON string" do
    assert_equal({}, @row_builder.ensure_hash("not json {{{"))
  end

  test "ensure_hash returns empty hash for JSON that parses to a non-Hash" do
    assert_equal({}, @row_builder.ensure_hash("[1,2,3]"))
    assert_equal({}, @row_builder.ensure_hash('"just a string"'))
    assert_equal({}, @row_builder.ensure_hash("42"))
  end

  test "ensure_hash returns empty hash for nil" do
    assert_equal({}, @row_builder.ensure_hash(nil))
  end

  test "ensure_hash returns empty hash for non-string non-hash types" do
    assert_equal({}, @row_builder.ensure_hash(42))
    assert_equal({}, @row_builder.ensure_hash([1, 2, 3]))
    assert_equal({}, @row_builder.ensure_hash(true))
  end

  test "ensure_hash returns empty hash for empty string" do
    assert_equal({}, @row_builder.ensure_hash(""))
  end

  test "cap_property_keys keeps at most MAX_PROPERTY_KEYS_PER_EVENT keys, deterministically" do
    max = Analytics::Config::MAX_PROPERTY_KEYS_PER_EVENT
    # Zero-padded keys so string-sort order is unambiguous (k001 < k002 < ... < k200).
    big = (1..200).index_by { |i| "k#{i.to_s.rjust(3, '0')}" }

    capped = @row_builder.cap_property_keys(big)

    assert_equal max, capped.size
    assert_equal big.keys.sort.first(max), capped.keys.sort
    # The deterministic subset is exactly the first N keys by string sort, with values intact.
    assert_equal 1, capped["k001"]
    assert_equal max, capped["k#{max.to_s.rjust(3, '0')}"]
    assert_nil capped["k#{(max + 1).to_s.rjust(3, '0')}"]
  end

  test "cap_property_keys passes through a hash under the cap unchanged" do
    assert_equal({ "a" => 1 }, @row_builder.cap_property_keys({ "a" => 1 }))
  end

  test "cap_property_keys passes through a hash exactly at the cap unchanged" do
    max = Analytics::Config::MAX_PROPERTY_KEYS_PER_EVENT
    at_cap = (1..max).index_by { |i| "k#{i.to_s.rjust(3, '0')}" }

    capped = @row_builder.cap_property_keys(at_cap)

    assert_equal max, capped.size
    assert_equal at_cap, capped
  end

  test "build_clickhouse_row caps event properties to MAX_PROPERTY_KEYS_PER_EVENT" do
    max = Analytics::Config::MAX_PROPERTY_KEYS_PER_EVENT
    data = (1..200).index_by { |i| "k#{i.to_s.rjust(3, '0')}" }
    pg_row = {
      project_id: @project.id,
      device_id: @device.id,
      event: Grovs::Events::CUSTOM,
      event_name: "checkout",
      session_id: "sess-1",
      link_id: @link.id,
      platform: "ios",
      app_version: "1.0",
      build: "10",
      vendor_id: @device.vendor,
      engagement_time: 0,
      data: data,
      sdk_attributes: {},
      tags: [],
      ip: "1.1.1.1",
      remote_ip: "1.1.1.1",
      path: "/checkout",
      created_at: Time.current
    }

    row = GeoipService.stub(:lookup, { country: "", city: "" }) do
      @row_builder.build_row(pg_row, @device, @visitor, @link)
    end

    assert_equal max, row[:properties].size
    assert_equal data.keys.sort.first(max), row[:properties].keys.sort
  end

  test "build_clickhouse_row caps event sdk_attributes to MAX_PROPERTY_KEYS_PER_EVENT" do
    max = Analytics::Config::MAX_PROPERTY_KEYS_PER_EVENT
    attrs = (1..200).index_by { |i| "k#{i.to_s.rjust(3, '0')}" }
    @visitor.update_column(:sdk_attributes, attrs)
    pg_row = {
      project_id: @project.id,
      device_id: @device.id,
      event: Grovs::Events::CUSTOM,
      event_name: "checkout",
      session_id: "sess-1",
      link_id: @link.id,
      platform: "ios",
      app_version: "1.0",
      build: "10",
      vendor_id: @device.vendor,
      engagement_time: 0,
      data: {},
      sdk_attributes: {},
      tags: [],
      ip: "1.1.1.1",
      remote_ip: "1.1.1.1",
      path: "/checkout",
      created_at: Time.current
    }

    row = GeoipService.stub(:lookup, { country: "", city: "" }) do
      @row_builder.build_row(pg_row, @device, @visitor, @link)
    end

    assert_equal max, row[:sdk_attributes].size
    assert_equal attrs.keys.sort.first(max), row[:sdk_attributes].keys.sort
  end
end
