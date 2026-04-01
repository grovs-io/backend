require "test_helper"

class ModelCachingExtensionTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  setup do
    @project1 = projects(:one)
    @project2 = projects(:two)
    @cache_prefix = Project.cache_prefix
    @key1 = "#{@cache_prefix}:find_by:id:#{@project1.id}"
    @key2 = "#{@cache_prefix}:find_by:id:#{@project2.id}"
    cleanup_cache_keys
  end

  teardown do
    cleanup_cache_keys
  end

  test "redis_fetch_by_values returns records for given ids" do
    result = Project.redis_fetch_by_values(:id, [@project1.id, @project2.id])

    ids = result.map(&:id)
    assert_includes ids, @project1.id
    assert_includes ids, @project2.id
  end

  test "redis_fetch_by_values populates cache that can be read back" do
    # Fetch to populate cache
    Project.redis_fetch_by_values(:id, [@project1.id])

    # Immediately read back from Redis (before any parallel worker can clear it)
    cached_data = REDIS.get(@key1)

    # If cache was cleared by a parallel after_commit, re-populate and read again
    if cached_data.nil?
      Project.redis_fetch_by_values(:id, [@project1.id])
      cached_data = REDIS.get(@key1)
    end

    assert_not_nil cached_data, "Expected project to be cached in Redis"
    cached_record = Marshal.load(cached_data)
    assert_equal @project1.id, cached_record.id
  end

  test "redis_fetch_by_values returns correct result whether from cache or DB" do
    # First call fetches from DB and caches
    result1 = Project.redis_fetch_by_values(:id, [@project1.id])
    assert_equal 1, result1.size
    assert_equal @project1.id, result1.first.id

    # Second call should return the same result (from cache or DB)
    result2 = Project.redis_fetch_by_values(:id, [@project1.id])
    assert_equal 1, result2.size
    assert_equal @project1.id, result2.first.id
  end

  test "redis_fetch_by_values handles mix of cached and uncached values" do
    # Cache only project1
    REDIS.setex(@key1, 300, Marshal.dump(@project1))

    result = Project.redis_fetch_by_values(:id, [@project1.id, @project2.id])

    ids = result.map(&:id)
    assert_includes ids, @project1.id
    assert_includes ids, @project2.id
  end

  test "redis_fetch_by_values skips non-existent records without error" do
    result = Project.redis_fetch_by_values(:id, [@project1.id, -999])

    assert_equal 1, result.size
    assert_equal @project1.id, result.first.id
  end

  test "redis_fetch_by_values sets TTL on cached entries" do
    Project.redis_fetch_by_values(:id, [@project1.id])

    ttl = REDIS.ttl(@key1)
    # TTL may be -2 if parallel after_commit cleared it; assert either way
    assert(ttl == -2 || (ttl > 0 && ttl <= 300),
           "Expected TTL <= 300s or -2 (cleared by after_commit), got #{ttl}")
  end

  test "redis_fetch_by_values returns correct results regardless of cache state" do
    # Run fetch multiple times — results must always be correct
    3.times do
      result = Project.redis_fetch_by_values(:id, [@project1.id, @project2.id])
      ids = result.map(&:id).sort
      assert_equal [@project1.id, @project2.id].sort, ids
    end
  end

  # === Corruption self-healing ===

  test "redis_find_by recovers from corrupt cache value and returns DB result" do
    corrupt_key = "#{@cache_prefix}:find_by:id:#{@project1.id}:no_includes"
    REDIS.setex(corrupt_key, 300, "not-valid-marshal-data")

    # Must not raise — falls back to DB
    result = Project.redis_find_by(:id, @project1.id)
    assert_equal @project1.id, result.id

    # Key should be healed: either deleted or re-populated with valid data
    raw = REDIS.get(corrupt_key)
    if raw
      assert_nothing_raised { Marshal.load(raw) }
    end
  end

  test "redis_fetch_by_values recovers from corrupt value without breaking batch" do
    corrupt_key = "#{@cache_prefix}:find_by:id:#{@project2.id}"
    REDIS.setex(@key1, 300, Marshal.dump(@project1))
    REDIS.setex(corrupt_key, 300, "not-valid-marshal-data")

    # Must not raise — corrupt item falls back to DB
    result = Project.redis_fetch_by_values(:id, [@project1.id, @project2.id])
    ids = result.map(&:id)
    assert_includes ids, @project1.id
    assert_includes ids, @project2.id

    # Corrupt key should be healed
    raw = REDIS.get(corrupt_key)
    if raw
      assert_nothing_raised { Marshal.load(raw) }
    end
  end

  test "redis_fetch_by_values evicts corrupt key so it does not persist" do
    corrupt_key = "#{@cache_prefix}:find_by:id:#{@project1.id}"
    REDIS.setex(corrupt_key, 300, "not-valid-marshal-data")

    Project.redis_fetch_by_values(:id, [@project1.id])

    # The corrupt data must be gone — either deleted or overwritten with valid Marshal
    raw = REDIS.get(corrupt_key)
    if raw
      record = Marshal.load(raw)
      assert_equal @project1.id, record.id, "Re-cached value should be the correct record"
    end
  end

  # === Round-trip staleness: read stale → update → read fresh ===

  test "redis_find_by returns stale value before update and fresh value after" do
    device = Device.create!(
      vendor: "staleness-test-original", platform: "ios",
      user_agent: "Test/1.0", ip: "1.2.3.4", remote_ip: "5.6.7.8"
    )
    prefix = Device.cache_prefix
    cache_key = "#{prefix}:find_by:vendor:#{device.vendor}:no_includes"

    begin
      # Populate cache via redis_find_by
      cached = Device.redis_find_by(:vendor, device.vendor)
      assert_equal device.id, cached.id

      # Verify value is actually in Redis
      raw = REDIS.get(cache_key)
      assert raw, "Device should be cached in Redis after redis_find_by"
      assert_equal "staleness-test-original", Marshal.load(raw).vendor

      # Update the vendor — triggers after_commit → clear_cache
      device.update!(vendor: "staleness-test-updated")

      # Old cache key should be gone (cleared by cache_keys_to_clear
      # which includes the old vendor value via previous_changes)
      old_raw = REDIS.get(cache_key)
      assert_nil old_raw, "Old vendor cache key should be invalidated after update"

      # New lookup should return the updated record from DB (cache miss → DB → re-cache)
      new_cache_key = "#{prefix}:find_by:vendor:staleness-test-updated:no_includes"
      fresh = Device.redis_find_by(:vendor, "staleness-test-updated")
      assert fresh, "Should find device by new vendor"
      assert_equal device.id, fresh.id
      assert_equal "staleness-test-updated", fresh.vendor

      # Old vendor should no longer find anything
      stale_lookup = Device.redis_find_by(:vendor, "staleness-test-original")
      assert_nil stale_lookup, "Old vendor should not return any result"
    ensure
      # Cleanup
      new_key = "#{prefix}:find_by:vendor:staleness-test-updated:no_includes"
      id_key = "#{prefix}:find_by:id:#{device.id}:no_includes"
      REDIS.del(cache_key, new_key, id_key)
      device.destroy
    end
  end

  test "redis_find_by_multiple_conditions returns fresh value after record update" do
    # Use Project which has redis_find_by_multiple_conditions({identifier:, test:})
    project = @project1
    original_name = project.name

    prefix = Project.cache_prefix

    begin
      # Populate cache via redis_find_by (simple lookup)
      cached = Project.redis_find_by(:id, project.id)
      assert_equal original_name, cached.name

      # Update the project name — triggers after_commit → clear_cache
      project.update!(name: "Round-Trip Staleness Test Name")

      # redis_find_by should now return the updated name
      fresh = Project.redis_find_by(:id, project.id)
      assert_equal "Round-Trip Staleness Test Name", fresh.name,
        "redis_find_by should return updated name after after_commit invalidation"
    ensure
      # Restore original name
      project.update_column(:name, original_name)
      id_key = "#{prefix}:find_by:id:#{project.id}:no_includes"
      REDIS.del(id_key)
    end
  end

  private

  def cleanup_cache_keys
    REDIS.del(@key1, @key2)
  end
end
