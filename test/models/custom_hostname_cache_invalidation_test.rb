require "test_helper"

# End-to-end cache invalidation for CustomHostname.
#
# CacheKeyCoverageTest proves the keys are *listed* in cache_keys_to_clear; it does
# NOT prove that a real save evicts them, because after_commit :clear_cache never
# fires under transactional fixtures (the test transaction is rolled back, never
# committed). This class disables transactional fixtures so the real commit hook
# runs, warms the cache through the actual redis_find_by path, then asserts the
# cached record is genuinely evicted on update, rename, and destroy.
#
# Because there is no enclosing transaction to roll back, every created row is
# cleaned up explicitly in setup/teardown.
class CustomHostnameCacheInvalidationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  fixtures :instances, :projects, :domains

  setup do
    CustomHostname.delete_all
    REDIS.flushdb
  end

  teardown do
    CustomHostname.delete_all
    REDIS.flushdb
  end

  def cache_key(host)
    "custom_hostnames:find_by:hostname:#{host}:no_includes"
  end

  def cached?(host)
    !REDIS.get(cache_key(host)).nil?
  end

  def create_hostname(host, **attrs)
    CustomHostname.create!({ project: projects(:one), domain: domains(:one),
                             hostname: host, status: "active", source: "saas" }.merge(attrs))
  end

  test "warming the lookup actually caches the record (read path)" do
    ch = create_hostname("links.warm.com")
    assert_not cached?("links.warm.com"), "nothing should be cached before the first lookup"

    found = CustomHostname.redis_find_by(:hostname, "links.warm.com")

    assert_equal ch.id, found.id
    assert cached?("links.warm.com"), "redis_find_by must populate the cache"
  end

  test "updating a custom hostname evicts its cached find_by:hostname entry" do
    create_hostname("links.evict.com")
    CustomHostname.redis_find_by(:hostname, "links.evict.com")
    assert cached?("links.evict.com"), "precondition: the record should be cached"

    CustomHostname.find_by!(hostname: "links.evict.com").update!(status: "suspended")

    assert_not cached?("links.evict.com"),
               "a committed update must run after_commit :clear_cache and evict the stale record"
  end

  test "renaming a hostname evicts the stale entry for the OLD hostname" do
    # The record is cached under its old hostname; the rename must evict that stale
    # key, not just the new one. This is the previous_changes branch the manifest
    # test can't reach.
    ch = create_hostname("old.rename.com")
    CustomHostname.redis_find_by(:hostname, "old.rename.com")
    assert cached?("old.rename.com"), "precondition: cached under the old hostname"

    ch.update!(hostname: "new.rename.com")

    assert_not cached?("old.rename.com"),
               "rename must evict the previous hostname's cached record"
  end

  test "destroying a custom hostname evicts its cached entry" do
    ch = create_hostname("links.gone.com")
    CustomHostname.redis_find_by(:hostname, "links.gone.com")
    assert cached?("links.gone.com")

    ch.destroy!

    assert_not cached?("links.gone.com"), "destroy must run after_commit :clear_cache and evict the record"
  end
end
