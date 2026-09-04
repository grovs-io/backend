# frozen_string_literal: true

require 'test_helper'

class Analytics::VisitorIdentitySyncServiceTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
  end

  test 'mirrors every PG visitor identity for the project into ClickHouse' do
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)

    rows = identities(@project.id).index_by { |r| r['visitor_id'].to_i }
    ios = visitors(:ios_visitor)
    android = visitors(:android_visitor)

    assert_equal 'user_ios_abc123', rows[ios.id]['sdk_identifier']
    assert_equal ios.uuid, rows[ios.id]['uuid']
    assert_equal 'user_android_xyz789', rows[android.id]['sdk_identifier']
  end

  test 'a visitor with no sdk_identifier syncs as an empty string, not a null' do
    v = Visitor.create!(project: @project, device: devices(:ios_device), web_visitor: false,
                        sdk_identifier: nil, uuid: SecureRandom.uuid)

    Analytics::VisitorIdentitySyncService.sync_project(@project.id)

    row = identities(@project.id).find { |r| r['visitor_id'].to_i == v.id }
    assert_equal '', row['sdk_identifier']
    assert_equal v.uuid, row['uuid']
  end

  test 're-syncing an updated identifier replaces the old row rather than duplicating it' do
    v = visitors(:ios_visitor)
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)
    v.update!(sdk_identifier: 'user_renamed')

    Analytics::VisitorIdentitySyncService.sync_project(@project.id)

    rows = identities(@project.id).select { |r| r['visitor_id'].to_i == v.id }
    assert_equal 1, rows.length, 'the published generation must hold one row per visitor'
    assert_equal 'user_renamed', rows.first['sdk_identifier']
  end

  test 'a visitor deleted in PG (merged away) is dropped on the next sync' do
    v = Visitor.create!(project: @project, device: devices(:ios_device), web_visitor: false,
                        sdk_identifier: 'merged_away', uuid: SecureRandom.uuid)
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)
    assert_includes identities(@project.id).map { |r| r['visitor_id'].to_i }, v.id

    NotificationMessage.where(visitor_id: v.id).delete_all
    v.delete

    Analytics::VisitorIdentitySyncService.sync_project(@project.id)

    ids = identities(@project.id).map { |r| r['visitor_id'].to_i }
    assert_not_includes ids, v.id, 'insert-only sync would leave the merged-away identity forever'
  end

  test 'a failed sync leaves the previous snapshot published and intact' do
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)
    before = published(@project.id)
    assert_not_empty before

    boom = ->(*) { raise ClickHouse::Client::DatabaseError, 'insert exploded' }
    assert_raises(ClickHouse::Client::DatabaseError) do
      Analytics::VisitorIdentitySyncService.stub(:insert_batch, boom) do
        Analytics::VisitorIdentitySyncService.sync_project(@project.id)
      end
    end

    assert_equal before, published(@project.id),
                 'a half-written generation must never be published over a good one'
  end

  # Under RMT keyed on (project_id, visitor_id) an unpublished row shadowed the published one.
  test 'a partially-written generation that fails before publishing leaves the snapshot complete' do
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)
    before = published(@project.id)
    assert_operator before.length, :>=, 2

    calls = 0
    partial_then_fail = lambda do |rows|
      calls += 1
      raise ClickHouse::Client::DatabaseError, 'died after first batch' if calls > 1

      Clickhouse.with { |c| c.insert('visitor_identities', rows) }
    end

    assert_raises(ClickHouse::Client::DatabaseError) do
      Analytics::VisitorIdentitySyncService.stub(:batch_size, 1) do
        Analytics::VisitorIdentitySyncService.stub(:insert_batch, partial_then_fail) do
          Analytics::VisitorIdentitySyncService.sync_project(@project.id)
        end
      end
    end

    assert_equal before, published(@project.id),
                 'rows from an unpublished generation must not shadow the published snapshot'
  end

  # A scale mismatch between the generation literal and synced_at makes the prune eat its own rows.
  test 'the prune keeps the generation it just published, marker included' do
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)
    settle_mutations

    assert_not_empty published(@project.id), 'prune deleted the live snapshot'
    marker = Clickhouse.with do |c|
      c.select_value("SELECT count() FROM visitor_identities WHERE project_id = #{@project.id} AND visitor_id = 0")
    end
    assert_equal 1, marker.to_i, 'the coverage marker must survive its own prune'
    assert ClickhouseReadService.visitor_identity_coverage?(@project.id), 'coverage must stay true after a sync'
  end

  # Generations must not share an ORDER BY key, or a merge collapses them mid-resync.
  test 'a merge cannot collapse one generation into another' do
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)
    before = published(@project.id)

    Clickhouse.with { |c| c.insert('visitor_identities', before.map { |r| next_generation_row(r) }) }
    Clickhouse.with { |c| c.execute('OPTIMIZE TABLE visitor_identities FINAL') }

    assert_equal before, published(@project.id),
                 'an unpublished newer generation must survive a merge without eating the published one'
  end

  test 'a sync after a clock rollback still becomes the published generation' do
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)
    visitors(:ios_visitor).update!(sdk_identifier: 'after_rollback')

    Time.stub(:current, Time.current - 1.hour) do
      Analytics::VisitorIdentitySyncService.sync_project(@project.id)
    end

    row = published(@project.id).find { |r| r['visitor_id'].to_i == visitors(:ios_visitor).id }
    assert_equal 'after_rollback', row['sdk_identifier'],
                 'a backwards clock must not strand the newer snapshot behind an older marker'
  end

  test 'two syncs within the same wall-clock instant still produce distinct generations' do
    frozen = Time.current
    Time.stub(:current, frozen) do
      Analytics::VisitorIdentitySyncService.sync_project(@project.id)
      visitors(:ios_visitor).update!(sdk_identifier: 'same_instant')
      Analytics::VisitorIdentitySyncService.sync_project(@project.id)
    end

    rows = published(@project.id).select { |r| r['visitor_id'].to_i == visitors(:ios_visitor).id }
    assert_equal 1, rows.length, 'equal timestamps must not blend two snapshots'
    assert_equal 'same_instant', rows.first['sdk_identifier']
  end

  # Generation allocation is a read-then-write; without the lock two runs blend into one snapshot.
  test 'a second concurrent sync for the same project is refused, not blended' do
    inner_error = nil
    attempted = false
    reentrant = lambda do |rows|
      unless attempted
        attempted = true
        begin
          Analytics::VisitorIdentitySyncService.sync_project(@project.id)
        rescue Analytics::VisitorIdentitySyncService::ConcurrentSyncError => e
          inner_error = e
        end
      end
      Clickhouse.with { |c| c.insert('visitor_identities', rows) }
    end

    Analytics::VisitorIdentitySyncService.stub(:insert_batch, reentrant) do
      Analytics::VisitorIdentitySyncService.sync_project(@project.id)
    end

    assert_instance_of Analytics::VisitorIdentitySyncService::ConcurrentSyncError, inner_error
    generations = Clickhouse.with do |c|
      c.select_all("SELECT DISTINCT synced_at FROM visitor_identities WHERE project_id = #{@project.id}")
    end
    assert_equal 1, generations.length, 'a refused run must not leave a second generation behind'
  end

  test 'the per-project lock is released so a later sync can run' do
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)

    assert_nothing_raised { Analytics::VisitorIdentitySyncService.sync_project(@project.id) }
  end

  test 'a failed sync still releases its lock' do
    boom = ->(*) { raise ClickHouse::Client::DatabaseError, 'boom' }
    assert_raises(ClickHouse::Client::DatabaseError) do
      Analytics::VisitorIdentitySyncService.stub(:insert_batch, boom) do
        Analytics::VisitorIdentitySyncService.sync_project(@project.id)
      end
    end

    assert_nothing_raised { Analytics::VisitorIdentitySyncService.sync_project(@project.id) }
  end

  # Losing the lock mid-run means another sync may be writing; publishing anyway is the interleave.
  test 'losing the lock mid-run aborts instead of publishing an interleaved snapshot' do
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)
    before = published(@project.id)

    steal = lambda do |rows|
      Clickhouse.with { |c| c.insert('visitor_identities', rows) }
      REDIS.with { |c| c.set("clickhouse:identity_sync:#{@project.id}", 'someone-else') }
    end

    assert_raises(Analytics::VisitorIdentitySyncService::LockLostError) do
      Analytics::VisitorIdentitySyncService.stub(:insert_batch, steal) do
        Analytics::VisitorIdentitySyncService.sync_project(@project.id)
      end
    end

    assert_equal before, published(@project.id), 'the aborted run must not publish'
  ensure
    REDIS.with { |c| c.del("clickhouse:identity_sync:#{@project.id}") }
  end

  test 'a visitor added between syncs appears only after the new generation is published' do
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)
    v = Visitor.create!(project: @project, device: devices(:ios_device), web_visitor: false,
                        sdk_identifier: 'late_arrival', uuid: SecureRandom.uuid)

    assert_not_includes published(@project.id).map { |r| r['sdk_identifier'] }, 'late_arrival'

    Analytics::VisitorIdentitySyncService.sync_project(@project.id)

    assert_includes published(@project.id).map { |r| r['sdk_identifier'] }, 'late_arrival'
  end

  test 'only syncs the requested project (tenant isolation)' do
    other = projects(:two)
    Visitor.create!(project: other, device: devices(:android_device), web_visitor: false,
                    sdk_identifier: 'other_tenant', uuid: SecureRandom.uuid)

    Analytics::VisitorIdentitySyncService.sync_project(@project.id)

    assert_empty identities(other.id), 'a different project must not be synced'
    assert_not_includes identities(@project.id).map { |r| r['sdk_identifier'] }, 'other_tenant'
  end

  test 'reports how many identities it synced' do
    count = Analytics::VisitorIdentitySyncService.sync_project(@project.id)
    assert_equal Visitor.where(project_id: @project.id).count, count
  end

  private

  def identities(project_id)
    published(project_id)
  end

  # Lightweight DELETE is a mutation; without settling, a read-back sees pre-mutation state.
  def settle_mutations
    Clickhouse.with do |c|
      c.execute('SYSTEM START MERGES visitor_identities') rescue nil
      50.times do
        pending = c.select_value("SELECT count() FROM system.mutations WHERE table = 'visitor_identities' " \
                                 'AND database = currentDatabase() AND is_done = 0').to_i
        break if pending.zero?

        sleep 0.05
      end
    end
  end

  # A published row restamped one second later: an unpublished newer generation.
  def next_generation_row(row)
    {
      project_id: @project.id, visitor_id: row['visitor_id'].to_i,
      sdk_identifier: "#{row['sdk_identifier']}_newer", uuid: row['uuid'].to_s,
      synced_at: (Time.current + 1).utc.strftime('%Y-%m-%d %H:%M:%S.%9N')
    }
  end

  # Only the latest fully-published generation, mirroring what the profile backfill reads.
  def published(project_id)
    Clickhouse.with do |conn|
      conn.select_all(
        'SELECT visitor_id, sdk_identifier, uuid FROM visitor_identities ' \
        "WHERE project_id = #{Integer(project_id)} AND visitor_id != 0 AND synced_at = " \
        "#{Analytics::VisitorIdentitySyncService.published_generation_sql(project_id)} " \
        'ORDER BY visitor_id'
      )
    end
  end
end
