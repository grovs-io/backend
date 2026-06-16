require "test_helper"

class MigratedLinkCleanupJobTest < ActiveJob::TestCase
  include MigrationFixtureHelpers

  fixtures :projects, :instances, :domains, :redirect_configs, :custom_hostnames,
           :migration_sources, :links

  setup do
    reset_acme_active_to_active!
    @source = migration_sources(:acme_branch)
    @source.update!(credentials: { "branch_key" => "x" })
    MigratedLink.delete_all
  end

  def make_row(status:, cached_until:, old_path: SecureRandom.hex(4), link: nil)
    MigratedLink.create!(
      migration_source: @source, link: link, old_path: old_path,
      status: status, cached_until: cached_until
    )
  end

  test "deletes not_found rows whose cached_until is older than the 7-day grace" do
    stale  = make_row(status: MigratedLink::STATUS_NOT_FOUND, cached_until: 10.days.ago)
    recent = make_row(status: MigratedLink::STATUS_NOT_FOUND, cached_until: 1.hour.ago)
    assert_equal 2, MigratedLink.count
    MigratedLinkCleanupJob.new.perform
    assert_nil MigratedLink.find_by(id: stale.id)
    assert_not_nil MigratedLink.find_by(id: recent.id)
  end

  test "deletes transient_error rows whose cached_until is older than the 7-day grace" do
    stale = make_row(status: MigratedLink::STATUS_TRANSIENT_ERROR, cached_until: 8.days.ago)
    MigratedLinkCleanupJob.new.perform
    assert_nil MigratedLink.find_by(id: stale.id)
  end

  test "NEVER deletes resolved rows regardless of age" do
    resolved_old = make_row(status: MigratedLink::STATUS_RESOLVED, cached_until: nil, link: links(:basic_link))
    # Even with an old cached_until (defensive against future schema change)
    weird = MigratedLink.new(migration_source: @source, old_path: "weird",
                             status: MigratedLink::STATUS_RESOLVED, link: links(:basic_link),
                             cached_until: 30.days.ago)
    weird.save!(validate: false)
    MigratedLinkCleanupJob.new.perform
    assert_not_nil MigratedLink.find_by(id: resolved_old.id)
    assert_not_nil MigratedLink.find_by(id: weird.id)
  end

  test "returns deleted count" do
    3.times { make_row(status: MigratedLink::STATUS_NOT_FOUND, cached_until: 10.days.ago) }
    count = MigratedLinkCleanupJob.new.perform
    assert_equal 3, count
  end

  test "no-op when nothing matches" do
    make_row(status: MigratedLink::STATUS_NOT_FOUND, cached_until: 1.hour.ago)
    count = MigratedLinkCleanupJob.new.perform
    assert_equal 0, count
    assert_equal 1, MigratedLink.count
  end

  test "preserves rows with cached_until exactly at the cutoff" do
    # cached_until = exactly 7 days ago should NOT be deleted (we use < cutoff, not <=)
    edge = make_row(status: MigratedLink::STATUS_NOT_FOUND, cached_until: 7.days.ago + 1.minute)
    MigratedLinkCleanupJob.new.perform
    assert_not_nil MigratedLink.find_by(id: edge.id)
  end

  # Cleanup uses `in_batches(of: BATCH_SIZE).delete_all` — spanning multiple batches must
  # delete every eligible row and only those. Test with BATCH_SIZE stubbed down so we don't
  # need 10k rows just to cross the boundary.
  test "deletes every eligible row across multiple batches without touching resolved rows" do
    original = MigratedLinkCleanupJob::BATCH_SIZE
    MigratedLinkCleanupJob.send(:remove_const, :BATCH_SIZE)
    MigratedLinkCleanupJob.const_set(:BATCH_SIZE, 3)

    stale    = Array.new(7) { make_row(status: MigratedLink::STATUS_NOT_FOUND, cached_until: 10.days.ago) }
    resolved = make_row(status: MigratedLink::STATUS_RESOLVED, cached_until: nil, link: links(:basic_link))

    deleted = MigratedLinkCleanupJob.new.perform
    assert_equal 7, deleted
    stale.each { |r| assert_nil MigratedLink.find_by(id: r.id) }
    assert_not_nil MigratedLink.find_by(id: resolved.id), "resolved rows must survive a multi-batch sweep"
  ensure
    MigratedLinkCleanupJob.send(:remove_const, :BATCH_SIZE)
    MigratedLinkCleanupJob.const_set(:BATCH_SIZE, original)
  end
end
