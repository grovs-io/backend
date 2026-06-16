require "test_helper"

class MigratedLinkTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :domains, :redirect_configs, :custom_hostnames,
           :migration_sources, :migrated_links, :links

  test "unique on (migration_source_id, old_path)" do
    src = migration_sources(:acme_branch)
    MigratedLink.create!(migration_source: src, old_path: "abc", status: MigratedLink::STATUS_NOT_FOUND, cached_until: 24.hours.from_now)
    assert_raises(ActiveRecord::RecordInvalid) do
      MigratedLink.create!(migration_source: src, old_path: "abc", status: MigratedLink::STATUS_NOT_FOUND, cached_until: 24.hours.from_now)
    end
  end

  test "status enum accepts resolved/not_found/transient_error" do
    src = migration_sources(:acme_branch)
    MigratedLink::ALL_STATUSES.each_with_index do |status, idx|
      ml = MigratedLink.new(migration_source: src, old_path: "valid-#{idx}", status: status, cached_until: 1.hour.from_now)
      assert ml.valid?, "expected #{status} to be valid"
    end
  end

  test "status enum rejects unknown values" do
    src = migration_sources(:acme_branch)
    ml = MigratedLink.new(migration_source: src, old_path: "x", status: "bogus")
    assert_not ml.valid?
  end

  test "link is nullable for negative-cache rows" do
    src = migration_sources(:acme_branch)
    ml = MigratedLink.create!(migration_source: src, old_path: "missing", status: MigratedLink::STATUS_NOT_FOUND, cached_until: 24.hours.from_now)
    assert_nil ml.link_id
  end

  test "cached_until is nullable for resolved rows (permanent cache)" do
    src = migration_sources(:acme_branch)
    link = links(:basic_link)
    ml = MigratedLink.create!(migration_source: src, link: link, old_path: "p", status: MigratedLink::STATUS_RESOLVED, cached_until: nil)
    assert_nil ml.cached_until
  end

  test "empty old_path allowed (host-root click)" do
    src = migration_sources(:acme_branch)
    ml = MigratedLink.create!(migration_source: src, old_path: "", status: MigratedLink::STATUS_RESOLVED, link: links(:basic_link))
    assert_equal "", ml.old_path
  end

  # ---------------------------------------------------------------------------
  # Cache invalidation (upsert bypasses after_commit, so FirstHitMigration must
  # explicitly call invalidate_cache_for after each upsert — this test asserts the
  # key format matches what redis_find_by_multiple_conditions actually writes).
  # ---------------------------------------------------------------------------

  test "invalidate_cache_for deletes the same Redis key that redis_find_by_multiple_conditions writes" do
    src = migration_sources(:acme_branch)
    # Warm the cache with a real lookup.
    MigratedLink.create!(migration_source: src, old_path: "warm", status: MigratedLink::STATUS_NOT_FOUND,
                         cached_until: 1.hour.from_now)
    MigratedLink.redis_find_by_multiple_conditions({ migration_source_id: src.id, old_path: "warm" })

    # Find the cache key the helper would have written
    transient = MigratedLink.new(migration_source_id: src.id, old_path: "warm")
    key = transient.cache_keys_to_clear.find { |k| k.include?("find_by:") && !k.include?("find_by:id:") }
    assert_not_nil key, "expected a multi_condition_cache_key in cache_keys_to_clear"
    assert_not_nil REDIS.with { |c| c.get(key) }, "expected the cache to be populated after the warm lookup"

    # Invalidate
    MigratedLink.invalidate_cache_for(migration_source_id: src.id, old_path: "warm")
    assert_nil REDIS.with { |c| c.get(key) }, "expected the cache key to be gone after invalidation"
  end

  test "invalidate_cache_for is a no-op when Redis is empty (no exceptions)" do
    src = migration_sources(:acme_branch)
    assert_nothing_raised do
      MigratedLink.invalidate_cache_for(migration_source_id: src.id, old_path: "nothing-cached")
    end
  end

  # ---------------------------------------------------------------------------
  # DB-level CHECK constraint on `status` — defense in depth against the
  # `upsert`/`upsert_all` path that FirstHitMigration uses (bypasses model
  # validations). Without the constraint, a typo'd status would land as a row
  # the resolver's `case` statement silently nils on — every click then
  # re-runs FirstHitMigration forever for that slug.
  #
  # We assert the constraint via direct SQL so the test exercises what the
  # DB-only path actually does, NOT the model-level inclusion validator (which
  # is covered by "status enum rejects unknown values" above).
  # ---------------------------------------------------------------------------

  test "DB CHECK constraint rejects an unknown status via raw INSERT (bypasses model validations)" do
    src = migration_sources(:acme_branch)
    # Raw SQL — the model's validates :inclusion never fires here. The test
    # would silently pass if the migration that added the constraint were
    # reverted; that's exactly the regression we want loud about.
    sql = <<~SQL.squish
      INSERT INTO migrated_links (migration_source_id, old_path, status, created_at, updated_at)
      VALUES (#{src.id}, 'bypass-validation', 'bogus_status_value', NOW(), NOW())
    SQL

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.connection.execute(sql)
    end
    assert_match(/migrated_links_status_check/, error.message,
                 "the migrated_links_status_check constraint must fire when status is outside the enum")
  end

  test "DB CHECK constraint accepts every status in ALL_STATUSES via raw INSERT" do
    src = migration_sources(:acme_branch)
    # Reverse of the above: the constraint must NOT reject valid values, or
    # FirstHitMigration's upsert path would 500 on legitimate writes.
    MigratedLink::ALL_STATUSES.each_with_index do |status, i|
      sql = <<~SQL.squish
        INSERT INTO migrated_links (migration_source_id, old_path, status, created_at, updated_at)
        VALUES (#{src.id}, 'allowed-#{i}', '#{status}', NOW(), NOW())
      SQL
      begin
        ActiveRecord::Base.connection.execute(sql)
      rescue ActiveRecord::StatementInvalid => e
        flunk "status '#{status}' must satisfy the CHECK constraint, got: #{e.message}"
      end
      assert MigratedLink.exists?(migration_source_id: src.id, old_path: "allowed-#{i}", status: status),
             "raw INSERT for status '#{status}' must persist successfully"
    end
  end
end
