require "test_helper"

class SegmentsMembersTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  fixtures :instances, :projects, :devices, :visitors

  setup do
    skip_unless_clickhouse!
    @__clickhouse_test_started = true
    @project = projects(:one)
    device = Device.create!(user_agent: "TestApp/1.0", ip: "192.168.1.9", remote_ip: "10.0.0.9", platform: "ios")
    extra = Visitor.create!(project: @project, device: device, sdk_identifier: "user_extra")
    @visitors = (Visitor.where(project_id: @project.id, id: [visitors(:ios_visitor).id, visitors(:android_visitor).id]).to_a + [extra]).sort_by(&:id)
    @manifest = Segments::Results::Manifest.new(result_id: "b" * 32, project_id: @project.id, persons: 3, devices: 3, rows: 4, incomplete: false)
    rows = @visitors.map { |v| { project_id: @project.id, result_id: @manifest.result_id, visitor_id: v.id, eff_visitor_id: v.id, person_key: "v:#{v.id}" } }
    # Sentinels must sort after every real id — fixture ids are large hashes, not sequentials.
    missing_eff = @visitors.last.id + 1
    rows << { project_id: @project.id, result_id: @manifest.result_id, visitor_id: @visitors.last.id + 2,
              eff_visitor_id: @visitors.first.id, person_key: "v:#{@visitors.first.id}" }
    rows << { project_id: @project.id, result_id: @manifest.result_id, visitor_id: missing_eff,
              eff_visitor_id: missing_eff, person_key: "v:#{missing_eff}" }
    Clickhouse.with { |c| c.insert("segment_results", rows) }
  end

  test "pages effective visitors once each, in id order, with a keyset cursor" do
    first = Segments::Members.page(manifest: @manifest, limit: 2)
    assert_equal @visitors.first(2).map(&:id), first[:users].map { |u| u["id"] }
    assert_equal @visitors[1].id, first[:next_after]
    rest = Segments::Members.page(manifest: @manifest, after: first[:next_after], limit: 2)
    assert_equal [@visitors[2].id], rest[:users].map { |u| u["id"] }
    assert_nil rest[:next_after]
  end

  test "one-at-a-time paging walks the sort key and still yields each effective visitor once" do
    seen = []
    sqls = []
    read = Segments::Runner.method(:read)
    Segments::Runner.stub(:read, ->(sql, **kw) { sqls << sql && read.call(sql, **kw) }) do
      after = 0
      loop do
        page = Segments::Members.page(manifest: @manifest, after: after, limit: 1)
        seen.concat(page[:users].map { |u| u["id"] })
        break unless (after = page[:next_after])
      end
    end
    assert_equal @visitors.map(&:id), seen
    assert(sqls.all? { |sql| sql.include?("ORDER BY visitor_id LIMIT") && !sql.include?("GROUP BY") })
  end

  test "in-app membership pages read the same one row per effective visitor" do
    old = InAppMemberships::PAGE
    InAppMemberships.send(:remove_const, :PAGE)
    InAppMemberships.const_set(:PAGE, 2)
    first = InAppMemberships.members(@manifest, 0)
    assert_equal @visitors.first(2).map(&:id), first
    assert_equal [@visitors[2].id, @visitors.last.id + 1], InAppMemberships.members(@manifest, first.last)
  ensure
    InAppMemberships.send(:remove_const, :PAGE)
    InAppMemberships.const_set(:PAGE, old)
  end

  test "rows carry the person key and drop visitors that no longer exist in Postgres" do
    all = Segments::Members.page(manifest: @manifest, limit: 50)
    assert_equal 3, all[:users].size
    assert_equal "v:#{@visitors.first.id}", all[:users].first["person_key"]
  end

  test "cursor round-trips and garbage is an expired result" do
    token = Segments::Members.encode_cursor("c" * 32, 41)
    assert_equal ["c" * 32, 41, ""], Segments::Members.decode_cursor(token)
    assert_raises(Segments::ResultExpired) { Segments::Members.decode_cursor("not-a-cursor") }
  end

  test "limit is clamped to max" do
    page = Segments::Members.page(manifest: @manifest, limit: 999, max: 2)
    assert_equal 2, page[:users].size
  end

  test "q narrows the page to identifier substrings or uuid prefixes and rides inside the cursor" do
    gen = Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
    rows = @visitors.map { |v| { project_id: @project.id, visitor_id: v.id, sdk_identifier: v.sdk_identifier.to_s, uuid: v.uuid.to_s, synced_at: gen } }
    rows << { project_id: @project.id, visitor_id: Analytics::VisitorIdentitySyncService::GENERATION_MARKER_VISITOR_ID,
              sdk_identifier: "", uuid: "", synced_at: gen }
    Clickhouse.with { |c| c.insert("visitor_identities", rows) }
    extra = @visitors.last
    page = Segments::Members.page(manifest: @manifest, limit: 50, q: "EXTRA")
    assert_equal [extra.id], page[:users].map { |u| u["id"] }
    assert_nil page[:next_after]
    by_uuid = Segments::Members.page(manifest: @manifest, limit: 50, q: extra.uuid.to_s.first(8).upcase)
    assert_equal [extra.id], by_uuid[:users].map { |u| u["id"] }
    assert_empty Segments::Members.page(manifest: @manifest, limit: 50, q: "no-such-user")[:users]
    assert_equal 3, Segments::Members.page(manifest: @manifest, limit: 50, q: "  ")[:users].size
    token = Segments::Members.encode_cursor(@manifest.result_id, 5, "EXTRA")
    assert_equal [@manifest.result_id, 5, "EXTRA"], Segments::Members.decode_cursor(token)
    assert_equal "", Segments::Members.decode_cursor(Segments::Members.encode_cursor(@manifest.result_id, 5)).last
  end

  test "search finds people only live user_profiles know, and their newest identifier wins" do
    now = Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%3N")
    first = @visitors.first
    extra = @visitors.last
    profiles = [[first, "live_renamed"], [extra, "user_extra"]].map do |v, ident|
      { project_id: @project.id, visitor_id: v.id, sdk_identifier: ident, uuid: v.uuid.to_s, properties: {}, first_seen: now, last_seen: now }
    end
    Clickhouse.with { |c| c.insert("user_profiles", profiles) }
    gen = (Time.current - 1.hour).utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
    marker = Analytics::VisitorIdentitySyncService::GENERATION_MARKER_VISITOR_ID
    Clickhouse.with do |c|
      c.insert("visitor_identities", [
        { project_id: @project.id, visitor_id: marker, sdk_identifier: "", uuid: "", synced_at: gen },
        { project_id: @project.id, visitor_id: first.id, sdk_identifier: "synced_name", uuid: "", synced_at: gen }
      ])
    end

    assert_equal [extra.id], Segments::Members.page(manifest: @manifest, limit: 50, q: "EXTRA")[:users].map { |u| u["id"] }
    assert_equal [extra.id], Segments::Members.page(manifest: @manifest, limit: 50, q: extra.uuid.to_s.first(8))[:users].map { |u| u["id"] }
    assert_equal [first.id], Segments::Members.page(manifest: @manifest, limit: 50, q: "live_renamed")[:users].map { |u| u["id"] }
    assert_empty Segments::Members.page(manifest: @manifest, limit: 50, q: "synced_name")[:users]
  end

  test "search ignores identity rows outside the published generation" do
    gen = Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
    stale = (Time.current - 1.hour).utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
    rows = [
      { project_id: @project.id, visitor_id: Analytics::VisitorIdentitySyncService::GENERATION_MARKER_VISITOR_ID, sdk_identifier: "", uuid: "",
synced_at: gen },
      { project_id: @project.id, visitor_id: @visitors.first.id, sdk_identifier: "renamed_user", uuid: "", synced_at: gen },
      { project_id: @project.id, visitor_id: @visitors.first.id, sdk_identifier: "old_name", uuid: "", synced_at: stale }
    ]
    Clickhouse.with { |c| c.insert("visitor_identities", rows) }
    assert_equal [@visitors.first.id], Segments::Members.page(manifest: @manifest, limit: 50, q: "renamed")[:users].map { |u| u["id"] }
    assert_empty Segments::Members.page(manifest: @manifest, limit: 50, q: "old_name")[:users]
  end
end
