# frozen_string_literal: true

require "test_helper"
require "sidekiq/testing"

class ClickhouseDeleteServiceTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :domains, :links

  setup do
    skip_unless_clickhouse!
    # Pins this class's own CH database, or its deletes wipe the previous class's rows.
    truncate_clickhouse_tables
    @ch_auto_rebuild_breakdowns = true

    @project = projects(:one)
    @project2 = projects(:two)
    @visitor = visitors(:ios_visitor)
    @device = devices(:ios_device)
    @link = links(:basic_link)

    @original_ch_enabled = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true
  end

  teardown do
    Rails.application.config.clickhouse_write_enabled = @original_ch_enabled if defined?(@original_ch_enabled)
    clear_tombstones
    REDIS.with { |c| c.del(ClickhouseWriteService::CANONICAL_DLQ_KEY) }
  end

  # Tombstones are keyed by project id, which fixture loading resets every run — clear
  # them so they don't leak across parallel-worker test runs.
  def clear_tombstones
    REDIS.with do |conn|
      cursor = "0"
      loop do
        cursor, keys = conn.scan(cursor, match: "#{ClickhouseDeleteService::TOMBSTONE_PREFIX}:*", count: 1000)
        conn.del(*keys) unless keys.empty?
        break if cursor == "0"
      end
    end
  end

  # --- helpers ---

  def ts(date_str = '2026-05-01', hour = 12)
    Time.utc(*date_str.split('-').map(&:to_i), hour, 0, 0).strftime('%Y-%m-%d %H:%M:%S.000')
  end

  def insert_event_row(project_id, visitor_id: 0, device_id: 0, link_id: 0, event_type: "open", campaign_id: 0)
    insert_ch_events({
      project_id: project_id,
      event_type: event_type,
      visitor_id: visitor_id,
      device_id: device_id,
      link_id: link_id,
      inviter_id: 0,
      campaign_id: campaign_id,
      platform: "ios",
      engagement_time: 0,
      country: "US",
      created_at: ts
    })
  end

  def insert_purchase_row(project_id, visitor_id: 0, device_id: 0, transaction_id: SecureRandom.hex(4))
    row = {
      project_id: project_id,
      event_type: "buy",
      purchase_type: "subscription",
      product_id: "premium",
      usd_price_cents: 999,
      currency: "USD",
      quantity: 1,
      transaction_id: transaction_id,
      original_transaction_id: transaction_id,
      store_source: "apple",
      device_id: device_id,
      link_id: 0,
      visitor_id: visitor_id,
      purchase_date: ts,
      created_at: ts
    }
    Clickhouse.with { |conn| conn.insert('purchase_events', [row]) }
  end

  def insert_user_profile(project_id, visitor_id)
    row = {
      project_id: project_id,
      visitor_id: visitor_id,
      device_id: 0,
      platform: "ios",
      country: "US",
      city: "",
      first_seen: ts,
      last_seen: ts
    }
    Clickhouse.with { |conn| conn.insert('user_profiles', [row]) }
  end

  def ch_count(table, project_id)
    Clickhouse.with { |conn| conn.select_value("SELECT COUNT(*) FROM `#{table}` WHERE project_id = #{Integer(project_id)}") }
  end

  # =====================================================================
  # 1. delete_projects: clears events table
  # =====================================================================

  test "delete_projects removes events for target project" do
    3.times { insert_event_row(@project.id) }

    ClickhouseDeleteService.delete_projects([@project.id])
    # ALTER TABLE DELETE is async in CH — wait for mutations
    sleep(1)

    assert_equal 0, ch_count('events', @project.id)
  end

  # =====================================================================
  # 2. delete_projects: clears purchase_events table
  # =====================================================================

  test "delete_projects removes purchase_events for target project" do
    2.times { insert_purchase_row(@project.id) }

    ClickhouseDeleteService.delete_projects([@project.id])
    sleep(1)

    assert_equal 0, ch_count('purchase_events', @project.id)
  end

  # =====================================================================
  # 3. delete_projects: clears user_profiles table
  # =====================================================================

  test "delete_projects removes user_profiles for target project" do
    insert_user_profile(@project.id, @visitor.id)

    ClickhouseDeleteService.delete_projects([@project.id])
    sleep(1)

    assert_equal 0, ch_count('user_profiles', @project.id)
  end

  # =====================================================================
  # 4. delete_projects: clears MV target tables (project_daily, link_daily, etc.)
  # =====================================================================

  test "delete_projects removes MV target tables for target project" do
    # Insert events that feed the MVs
    insert_event_row(@project.id, visitor_id: @visitor.id, link_id: @link.id)

    # Verify MVs were populated
    assert ch_count('project_daily', @project.id) > 0, "project_daily should have data before delete"
    assert ch_count('billing_active_visitors_daily', @project.id) > 0,
      "billing_active_visitors_daily should have data before delete"

    ClickhouseDeleteService.delete_projects([@project.id])
    sleep(1)

    assert_equal 0, ch_count('project_daily', @project.id)
    assert_equal 0, ch_count('link_daily', @project.id)
    assert_equal 0, ch_count('visitor_daily', @project.id)
    assert_equal 0, ch_count('project_country_daily', @project.id)
    assert_equal 0, ch_count('billing_active_visitors_daily', @project.id)
  end

  # =====================================================================
  # 5. delete_projects: clears purchase MV targets
  # =====================================================================

  test "delete_projects removes purchase MV target tables" do
    insert_purchase_row(@project.id, visitor_id: @visitor.id)

    # Verify MVs were populated
    assert ch_count('purchase_project_daily', @project.id) > 0, "purchase_project_daily should have data before delete"

    ClickhouseDeleteService.delete_projects([@project.id])
    sleep(1)

    assert_equal 0, ch_count('purchase_project_daily', @project.id)
    assert_equal 0, ch_count('purchase_product_daily', @project.id)
  end

  # =====================================================================
  # 6. Project isolation: other project data survives
  # =====================================================================

  test "delete_projects does not touch other project data" do
    insert_event_row(@project.id)
    insert_event_row(@project2.id)
    insert_purchase_row(@project.id)
    insert_purchase_row(@project2.id)

    ClickhouseDeleteService.delete_projects([@project.id])
    sleep(1)

    assert_equal 0, ch_count('events', @project.id), "Target project events deleted"
    assert_equal 1, ch_count('events', @project2.id), "Other project events untouched"
    assert_equal 0, ch_count('purchase_events', @project.id), "Target project purchases deleted"
    assert_equal 1, ch_count('purchase_events', @project2.id), "Other project purchases untouched"
  end

  # =====================================================================
  # 7. Multiple project IDs in one call
  # =====================================================================

  test "delete_projects handles multiple project IDs" do
    insert_event_row(@project.id)
    insert_event_row(@project2.id)

    ClickhouseDeleteService.delete_projects([@project.id, @project2.id])
    sleep(1)

    assert_equal 0, ch_count('events', @project.id)
    assert_equal 0, ch_count('events', @project2.id)
  end

  # =====================================================================
  # 8. Empty project_ids is a no-op
  # =====================================================================

  test "delete_projects with empty array does nothing" do
    insert_event_row(@project.id)

    ClickhouseDeleteService.delete_projects([])

    assert_equal 1, ch_count('events', @project.id), "Events should survive empty delete call"
  end

  # =====================================================================
  # 9. CH disabled: no-op, no error
  # =====================================================================

  test "delete_projects is no-op when CH disabled" do
    Rails.application.config.clickhouse_write_enabled = false

    insert_event_row(@project.id)

    ClickhouseDeleteService.delete_projects([@project.id])

    # Re-enable to verify data still there
    Rails.application.config.clickhouse_write_enabled = true
    assert_equal 1, ch_count('events', @project.id), "Events should survive when CH disabled"
  end

  # =====================================================================
  # 10. CH failure: logs error, does not raise
  # =====================================================================

  test "delete_projects logs error on CH failure and does not raise" do
    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:with, ->(&_blk) { raise StandardError, "CH down" }) do
        assert_nothing_raised do
          ClickhouseDeleteService.delete_projects([@project.id])
        end
      end
    end
  end

  # =====================================================================
  # 11. Integer sanitization: rejects non-integer project IDs
  # =====================================================================

  test "delete_projects rejects non-integer project IDs without reaching CH" do
    insert_event_row(@project.id)

    # Bad input is caught by Integer() and logged — no CH mutation happens
    ClickhouseDeleteService.delete_projects(["1; DROP TABLE events"])

    # Data still intact — the bad call was a no-op
    assert_equal 1, ch_count('events', @project.id)
  end

  # =====================================================================
  # 18. Integration: DeleteInstanceJob calls delete_projects
  # =====================================================================

  test "DeleteInstanceJob triggers CH cleanup for project data" do
    insert_event_row(@project.id, visitor_id: @visitor.id)
    insert_purchase_row(@project.id, visitor_id: @visitor.id)
    insert_user_profile(@project.id, @visitor.id)

    # Verify data exists
    assert ch_count('events', @project.id) > 0
    assert ch_count('purchase_events', @project.id) > 0
    assert ch_count('user_profiles', @project.id) > 0

    # Clean up FKs that block instance deletion (Stripe; and leaked custom_hostname
    # fixtures whose teardown would attempt a real Cloudflare delete in tests).
    StripeSubscription.where(instance_id: @project.instance_id).delete_all
    CustomHostname.unscoped.where(project_id: Project.where(instance_id: @project.instance_id).select(:id)).delete_all

    job = DeleteInstanceJob.new
    job.perform(@project.instance_id)

    sleep(1)

    assert_equal 0, ch_count('events', @project.id), "Events should be deleted after instance deletion"
    assert_equal 0, ch_count('purchase_events', @project.id), "Purchase events should be deleted"
    assert_equal 0, ch_count('user_profiles', @project.id), "User profiles should be deleted"
    assert_equal 0, ch_count('project_daily', @project.id), "project_daily should be deleted"
  end

  # =====================================================================
  # 18b. Deletion tombstones + DLQ resurrection guard
  # =====================================================================

  test "delete_projects tombstones the deleted project ids" do
    insert_event_row(@project.id)

    ClickhouseDeleteService.delete_projects([@project.id])

    assert_equal [@project.id], ClickhouseDeleteService.tombstoned_project_ids([@project.id])
  end

  test "reject_tombstoned drops only tombstoned project rows" do
    a = 800_001
    b = 800_002
    rows = [{ project_id: a }, { project_id: b }]

    assert_equal rows, ClickhouseDeleteService.reject_tombstoned(rows), "nothing tombstoned -> unchanged"

    ClickhouseDeleteService.tombstone_projects([a])

    assert_equal [{ project_id: b }], ClickhouseDeleteService.reject_tombstoned(rows)
    assert_equal [a], ClickhouseDeleteService.tombstoned_project_ids([a, b])
  end

  # The core race: a batch parked in the DLQ before the project was deleted must not
  # resurrect that project's rows when the DLQ drains after the delete.
  test "DLQ drain drops rows for a tombstoned project but replays the rest" do
    deleted_pid = 700_001
    kept_pid    = 700_002
    payload = {
      table: "events",
      rows: [
        { event_id: SecureRandom.hex(8), project_id: deleted_pid, event_type: "open", created_at: ts, ingested_at: ts },
        { event_id: SecureRandom.hex(8), project_id: kept_pid,    event_type: "open", created_at: ts, ingested_at: ts }
      ],
      error: "boom", at: "2026-07-11T00:00:00Z"
    }.to_json

    ClickhouseDeleteService.tombstone_projects([deleted_pid])
    REDIS.with do |c|
      c.del(ClickhouseWriteService::CANONICAL_DLQ_KEY)
      c.lpush(ClickhouseWriteService::CANONICAL_DLQ_KEY, payload)
    end

    drained = ClickhouseWriteService.drain_canonical_dlq(limit: 10)

    assert_equal 1, drained, "the parked batch is still consumed"
    assert_equal 0, ch_count('events', deleted_pid), "tombstoned project's row must not resurrect"
    assert_equal 1, ch_count('events', kept_pid), "the live project's row is replayed normally"
  end

  # =====================================================================
  # 19. Integration: MergeVisitorEventsJob records an identity-map alias
  #     instead of deleting the merged visitor's canonical CH data (Phase 4).
  # =====================================================================

  test "MergeVisitorEventsJob aliases the merged visitor and preserves canonical CH rows" do
    android_device = devices(:android_device)
    android_visitor = visitors(:android_visitor)

    insert_event_row(@project.id, visitor_id: @visitor.id)
    insert_event_row(@project.id, visitor_id: android_visitor.id)

    # Merge ios_visitor INTO android_visitor (ios_visitor = from, android = to).
    # The CH fold is a separate job now; run it inline so the alias is written here.
    Sidekiq::Testing.inline! do
      MergeVisitorEventsJob.new.perform(@device.id, android_device.id, @project.id)
    end

    # Canonical/raw event rows are IMMUTABLE — the merged visitor's events stay put.
    remaining_events = Clickhouse.with do |conn|
      conn.select_all("SELECT visitor_id FROM events WHERE project_id = #{@project.id}")
    end
    remaining_visitor_ids = remaining_events.map { |r| r['visitor_id'].to_i }.uniq
    assert_includes remaining_visitor_ids, @visitor.id, "Merged-away visitor's events must NOT be deleted"
    assert_includes remaining_visitor_ids, android_visitor.id, "Target visitor events remain"

    # The merge is recorded in the identity map (merged -> survivor).
    survivor = ClickhouseIdentityMapService.resolve(@project.id, @visitor.id)
    assert_equal android_visitor.id, survivor, "merged visitor must alias to the survivor"
  end

  # =====================================================================
  # 20. All PROJECT_TABLES are covered by delete_projects
  # =====================================================================

  test "PROJECT_TABLES covers EVERY project-scoped data table in ClickHouse (dynamic, self-maintaining)" do
    # Query the live schema so a NEW migration that adds a project-scoped table but forgets to
    # register it here FAILS this test — otherwise project deletion/retention would silently
    # leave that table's data behind (e.g. events was missed before this).
    sql = <<~SQL.squish
      SELECT DISTINCT t.name
      FROM system.tables t
      INNER JOIN system.columns c ON c.database = t.database AND c.table = t.name
      WHERE t.database = currentDatabase() AND c.name = 'project_id'
        AND t.engine != 'MaterializedView'
    SQL
    data_tables = Clickhouse.with { |conn| conn.select_all(sql) }.map { |r| r["name"] }
    missing = data_tables - ClickhouseDeleteService::PROJECT_TABLES
    assert_empty missing,
                 "project-scoped CH data tables not registered for deletion/retention: #{missing.inspect}"
  end

  # =====================================================================
  # delete_projects_before (date-bounded retention deletion)
  # =====================================================================

  def insert_event_at(project_id, created_at_date)
    insert_ch_events({
      project_id: project_id, event_type: "open", visitor_id: 0, device_id: 0,
      link_id: 0, inviter_id: 0, campaign_id: 0, platform: "ios",
      engagement_time: 0, country: "US",
      created_at: ts(created_at_date)
    })
  end

  def insert_purchase_at(project_id, purchase_date:, created_at:)
    Clickhouse.with do |conn|
      conn.insert('purchase_events', [{
        project_id: project_id, event_type: "buy", purchase_type: "subscription",
        product_id: "premium", usd_price_cents: 999, currency: "USD", quantity: 1,
        transaction_id: SecureRandom.hex(6), original_transaction_id: SecureRandom.hex(6),
        store_source: "apple", device_id: 0, link_id: 0, visitor_id: 0,
        purchase_date: ts(purchase_date), created_at: ts(created_at)
      }])
    end
  end

  def old_date
    (Date.current - 800).strftime('%Y-%m-%d')
  end

  def recent_date
    (Date.current - 10).strftime('%Y-%m-%d')
  end

  def wait_for_ch_mutations(table, timeout: 10)
    deadline = Time.now + timeout
    loop do
      pending = Clickhouse.with do |c|
        c.select_value("SELECT count() FROM system.mutations WHERE table = '#{table}' AND is_done = 0")
      end
      break if pending.to_i.zero?
      raise "CH mutations did not finish for #{table}" if Time.now > deadline

      sleep 0.1
    end
  end

  test "delete_projects_before removes only rows older than the cutoff" do
    pid = 987_654
    insert_event_at(pid, old_date)
    insert_event_at(pid, recent_date)
    assert_equal 2, ch_count('events', pid)

    ClickhouseDeleteService.delete_projects_before([pid], Date.current - 365)
    wait_for_ch_mutations('events')

    assert_equal 1, ch_count('events', pid), "row older than cutoff deleted, recent row kept"
  end

  test "delete_projects_before leaves untargeted projects untouched" do
    keep_pid = 111_222
    del_pid  = 333_444
    insert_event_at(keep_pid, old_date)
    insert_event_at(del_pid, old_date)

    ClickhouseDeleteService.delete_projects_before([del_pid], Date.current - 365)
    wait_for_ch_mutations('events')

    assert_equal 1, ch_count('events', keep_pid)
    assert_equal 0, ch_count('events', del_pid)
  end

  # purchase_events deletes on purchase_date, not created_at.
  test "delete_projects_before deletes purchase_events on purchase_date semantics" do
    pid = 555_666
    insert_purchase_at(pid, purchase_date: old_date,    created_at: recent_date) # delete: old purchase
    insert_purchase_at(pid, purchase_date: recent_date, created_at: old_date)    # keep: recent purchase

    ClickhouseDeleteService.delete_projects_before([pid], Date.current - 365)
    wait_for_ch_mutations('purchase_events')

    rows = Clickhouse.with do |c|
      c.select_all("SELECT toDate(purchase_date) AS d FROM purchase_events FINAL WHERE project_id = #{pid}")
    end
    assert_equal 1, rows.size, "exactly the old-purchase_date row should be deleted"
    assert_equal (Date.current - 10).to_s, rows.first['d'].to_s, "surviving row is the recent purchase"
  end

  test "delete_projects_before is a no-op (returns []) for empty project list" do
    assert_equal [], ClickhouseDeleteService.delete_projects_before([], Date.current - 365)
  end

  test "delete_projects_before rejects non-integer ids without touching CH" do
    pid = 777_888
    insert_event_at(pid, old_date)

    ClickhouseDeleteService.delete_projects_before(["1; DROP TABLE events"], Date.current - 365)

    assert_equal 1, ch_count('events', pid), "injection attempt is a no-op"
  end

  # A wrong date column raises in CH; [] proves every mapped column exists.
  test "every retention table maps to a real date column" do
    errors = ClickhouseDeleteService.delete_projects_before([424_242], Date.current - 365)

    assert_equal [], errors, "tables with bad/missing date columns: #{errors.inspect}"
  end

  test "a failing table is isolated and reported while valid tables still process" do
    pid = 999_111
    insert_event_at(pid, old_date)

    original = ClickhouseDeleteService::RETENTION_DATE_COLUMNS
    bad_map = original.merge("events" => "no_such_column").freeze
    silence_warnings do
      ClickhouseDeleteService.const_set(:RETENTION_DATE_COLUMNS, bad_map)
    end

    errors = ClickhouseDeleteService.delete_projects_before([pid], Date.current - 365)
    wait_for_ch_mutations('session_events')

    # events fails (bad column) but is captured, not raised; the row survives.
    assert(errors.any? { |e| e[:table] == "events" }, "failing table must be reported: #{errors.inspect}")
    assert_equal 1, ch_count('events', pid), "the table with the bad column was isolated, not silently 'succeeded'"
    # A valid table ordered after the failure still ran (no early abort).
    assert(errors.none? { |e| e[:table] == "session_events" }, "later valid tables must still process")
  ensure
    silence_warnings do
      ClickhouseDeleteService.const_set(:RETENTION_DATE_COLUMNS, original)
    end
  end

  test "RETENTION_DATE_COLUMNS covers every PROJECT_TABLE except the retention-exempt ones" do
    # Exempt (no date-based retention, only full-project delete): user_profiles (no date),
    # visitor_acquisition (whole-history aggregate), visitor_identity_map (aliases outlive windows).
    expected = ClickhouseDeleteService::PROJECT_TABLES - ClickhouseDeleteService::RETENTION_EXEMPT
    assert_equal expected.sort, ClickhouseDeleteService::RETENTION_DATE_COLUMNS.keys.sort
  end

  test "the retention-exempt tables are still fully wiped by a project delete" do
    # They skip date-retention but MUST NOT skip project deletion — otherwise a deleted project
    # leaves its identity map / acquisition state behind.
    ClickhouseDeleteService::RETENTION_EXEMPT.each do |t|
      assert_includes ClickhouseDeleteService::PROJECT_TABLES, t,
                      "#{t} is retention-exempt but must still be in PROJECT_TABLES for project delete"
    end
  end
end
