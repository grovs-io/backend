require "test_helper"

# Direct coverage for the SingleFlightJob mixin. Two cron-driven CF jobs depend on
# every invariant here, so regressions show up only in prod brownouts.
class SingleFlightJobTest < ActiveSupport::TestCase
  class TestJob
    include SingleFlightJob
    def run(key:, ttl:, &block)
      single_flight!(key: key, ttl: ttl, &block)
    end
  end

  def lock_key(name) = "sidekiq:single_flight:#{name}"

  setup do
    @keys_used = []
  end

  teardown do
    REDIS.with { |c| @keys_used.each { |k| c.del(lock_key(k)) } }
  end

  def use_key(name)
    @keys_used << name
    name
  end

  test "acquires when free and yields a deadline ≈ now + ttl" do
    key = use_key("acquire_#{SecureRandom.hex(4)}")
    yielded = nil
    travel_to Time.current do
      TestJob.new.run(key: key, ttl: 60.seconds) { |d| yielded = d }
      assert_in_delta((Time.current + 60).to_f, yielded.to_f, 0.5)
    end
  end

  test "skips the block when the lock is already held" do
    key = use_key("skip_#{SecureRandom.hex(4)}")
    REDIS.with { |c| c.set(lock_key(key), "external-token", nx: true, ex: 60) }
    ran = false
    TestJob.new.run(key: key, ttl: 60.seconds) { ran = true }
    assert_not ran, "block must not execute when lock already held"
    assert_equal "external-token", REDIS.with { |c| c.get(lock_key(key)) },
      "skipped run must not overwrite the holder's token"
  end

  test "releases the lock after the block returns" do
    key = use_key("release_#{SecureRandom.hex(4)}")
    TestJob.new.run(key: key, ttl: 60.seconds) { }
    assert_nil REDIS.with { |c| c.get(lock_key(key)) }
  end

  test "releases the lock when the block raises" do
    key = use_key("raise_#{SecureRandom.hex(4)}")
    assert_raises(RuntimeError) do
      TestJob.new.run(key: key, ttl: 60.seconds) { raise "boom" }
    end
    assert_nil REDIS.with { |c| c.get(lock_key(key)) },
      "ensure block must release even on exception"
  end

  # A Redis blip during release must NOT mark the Sidekiq job failed. If it did, Sidekiq
  # would retry — re-running the perform block that already performed its side effects,
  # duplicating maintenance work (e.g. the lifecycle job tearing down already-suspended
  # CF hostnames a second time). The SETNX TTL ensures lock auto-release regardless.
  test "Redis error during release does NOT propagate (Sidekiq won't retry the perform block)" do
    key = use_key("rescue_#{SecureRandom.hex(4)}")
    release_fail = false
    original = REDIS.method(:with)
    REDIS.define_singleton_method(:with) do |&blk|
      raise Redis::CannotConnectError, "down" if release_fail
      original.call(&blk)
    end

    block_ran = false
    assert_nothing_raised do
      TestJob.new.run(key: key, ttl: 60.seconds) do
        block_ran = true
        release_fail = true  # the next REDIS.with (the ensure-block release) raises
      end
    end
    assert block_ran, "the perform block must still execute"
  ensure
    REDIS.singleton_class.remove_method(:with) if REDIS.singleton_class.method_defined?(:with)
  end

  # Lock ownership invariant: if worker 1's TTL expires while it's still in the block
  # and worker 2 acquires the lock, worker 1's release MUST be a CAS no-op — never
  # stomp worker 2's lock. Without the token + Lua CAS, both workers run simultaneously.
  test "tokened CAS unlock does NOT delete a successor's lock" do
    key = use_key("cas_#{SecureRandom.hex(4)}")
    successor_token = "successor-#{SecureRandom.hex(8)}"

    TestJob.new.run(key: key, ttl: 60.seconds) do
      # Simulate TTL expiry mid-run + a second worker grabbing the lock.
      REDIS.with do |c|
        c.del(lock_key(key))
        c.set(lock_key(key), successor_token, nx: true, ex: 60)
      end
    end

    assert_equal successor_token, REDIS.with { |c| c.get(lock_key(key)) },
      "original worker's CAS unlock must not delete the successor's lock"
  end
end
