require "test_helper"

class SegmentsPermitsTest < ActiveSupport::TestCase
  include ConstStubHelper
  teardown do
    REDIS.with do |c|
      c.del(Segments::Permits::GLOBAL_KEY, Segments::Permits.project_key(1), Segments::Permits.project_key(2),
            Segments::Permits::LANES[:campaigns][:global_key], *[1, 2, 3].map { |i| Segments::Permits.project_key(i, lane: :campaigns) },
            Segments::Permits::LANES[:server][:global_key], Segments::Permits.project_key(1, lane: :server))
    end
  end

  test "a project is capped at two concurrent leases" do
    held = []
    inner = nil
    Segments::Permits.with(1, ttl: 30) do
      Segments::Permits.with(1, ttl: 30) do
        held << :two
        inner = assert_raises(Segments::Busy) { Segments::Permits.with(1, ttl: 30) { held << :three } }
      end
    end
    assert_equal [:two], held
    assert_kind_of Segments::Busy, inner
  end

  test "the lease is released when the block raises" do
    assert_raises(RuntimeError) { Segments::Permits.with(1, ttl: 30) { raise "boom" } }
    2.times { Segments::Permits.with(1, ttl: 30) { :ok } }
    assert_equal 0, REDIS.with { |c| c.zcard(Segments::Permits::GLOBAL_KEY) }
  end

  test "a leaked lease expires on its own" do
    REDIS.with { |c| c.zadd(Segments::Permits.project_key(2), Time.now.to_f - 1, "stale-a") }
    REDIS.with { |c| c.zadd(Segments::Permits.project_key(2), Time.now.to_f - 1, "stale-b") }
    assert_equal :ok, Segments::Permits.with(2, ttl: 30) { :ok }
  end

  test "the global cap spans projects" do
    with_const(Segments::Permits, :GLOBAL_LIMIT, 1) do
      Segments::Permits.with(1, ttl: 30) do
        assert_raises(Segments::Busy) { Segments::Permits.with(2, ttl: 30) { :no } }
      end
    end
  end

  test "the campaigns lane has its own pool and does not consume dashboard permits" do
    Segments::Permits.with(1, ttl: 5, lane: :campaigns) do
      Segments::Permits.with(2, ttl: 5, lane: :campaigns) do
        assert_raises(Segments::Busy) { Segments::Permits.with(3, ttl: 5, lane: :campaigns) { flunk "campaigns pool must be full" } }
        assert_nothing_raised { Segments::Permits.with(1, ttl: 5, lane: :dashboard) { :ok } }
      end
    end
    assert_nothing_raised { Segments::Permits.with(3, ttl: 5, lane: :campaigns) { :ok } }
  end

  test "the campaigns lane caps one evaluation per project and rejects unknown lanes" do
    Segments::Permits.with(1, ttl: 5, lane: :campaigns) do
      assert_raises(Segments::Busy) { Segments::Permits.with(1, ttl: 5, lane: :campaigns) { flunk "one per project" } }
    end
    assert_raises(ArgumentError) { Segments::Permits.with(1, ttl: 5, lane: :nope) { :ok } }
  end

  test "the server lane caps one query per project and leaves the dashboard lane free" do
    Segments::Permits.with(1, ttl: 5, lane: :server) do
      assert_raises(Segments::Busy) { Segments::Permits.with(1, ttl: 5, lane: :server) { flunk "one per project" } }
      Segments::Permits.with(1, ttl: 5) { Segments::Permits.with(1, ttl: 5) { :ok } }
    end
  end
end
