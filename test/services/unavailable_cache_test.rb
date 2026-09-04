# frozen_string_literal: true

require "test_helper"

class UnavailableCacheTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  KEY = "unavailable_cache_test:key"
  TTL = 5.minutes

  setup { @store = ActiveSupport::Cache::MemoryStore.new }

  def with_store(&block)
    Rails.stub(:cache, @store, &block)
  end

  test "a successful value caches for the full TTL" do
    calls = 0

    with_store do
      2.times { UnavailableCache.fetch(KEY, ttl: TTL) { calls += 1 } }
    end

    assert_equal 1, calls
  end

  test "an unavailable store answers the next caller from the marker instead of re-querying" do
    calls = 0
    failing = lambda do
      calls += 1
      raise RevenueLedger::Unavailable, "project_totals"
    end

    with_store do
      assert_raises(RevenueLedger::Unavailable) { UnavailableCache.fetch(KEY, ttl: TTL, &failing) }
      error = assert_raises(RevenueLedger::Unavailable) { UnavailableCache.fetch(KEY, ttl: TTL, &failing) }
      assert_equal "project_totals", error.message
    end

    assert_equal 1, calls, "the second caller must not re-run the failing query"
  end

  test "the marker expires well before the full TTL so recovery is not masked" do
    calls = 0
    failing = lambda do
      calls += 1
      raise Clickhouse::Stale, "rollups"
    end

    with_store do
      assert_raises(Clickhouse::Stale) { UnavailableCache.fetch(KEY, ttl: TTL, &failing) }
      travel(RevenueLedger::DEGRADED_CACHE_TTL + 1.second) do
        assert_equal :recovered, UnavailableCache.fetch(KEY, ttl: TTL) { :recovered }
      end
    end

    assert_equal 1, calls
  end

  test "an unrelated failure is never cached" do
    calls = 0
    failing = lambda do
      calls += 1
      raise ActiveRecord::StatementInvalid, "boom"
    end

    with_store do
      2.times do
        assert_raises(ActiveRecord::StatementInvalid) { UnavailableCache.fetch(KEY, ttl: TTL, &failing) }
      end
    end

    assert_equal 2, calls
  end
end
