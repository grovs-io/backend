require "test_helper"

class FirstHitMigrationTest < ActiveSupport::TestCase
  include MigrationFixtureHelpers

  fixtures :projects, :instances, :domains, :redirect_configs, :custom_hostnames,
           :migration_sources, :links

  setup do
    reset_acme_active_to_active!
    @source = migration_sources(:acme_branch)
    @source.update!(credentials: { "branch_key" => "k" })
    @project = @source.project
    # Clear any stale lock keys and rate-limit buckets across tests.
    REDIS.with do |c|
      %W[migration:lock:#{@source.id}:* migration:upstream_rate:#{@source.id}:*].each do |pattern|
        keys = c.keys(pattern)
        c.del(*keys) unless keys.empty?
      end
    end
  end

  def fake_response(code:, body: nil, headers: {})
    Struct.new(:code, :parsed_response, :headers).new(code, body, headers)
  end

  # ---------------------------------------------------------------------------
  # :found path
  # ---------------------------------------------------------------------------

  test "found outcome materializes Link + writes resolved cache row + record_success!" do
    @source.update_columns(consecutive_failures: 3, first_failure_at: 1.hour.ago)
    body = { "data" => { "$ios_url" => "myapp://ios", "$og_title" => "X" } }
    HTTParty.stub(:get, fake_response(code: 200, body: body)) do
      o = FirstHitMigration.call(source: @source, old_path: "abc")
      assert o.redirect?, "expected redirect, got #{o.kind}"
      assert_not_nil o.link
      assert_equal Grovs::Migrations::GENERATED_FROM_PLATFORM, o.link.generated_from_platform
    end
    row = MigratedLink.find_by(migration_source: @source, old_path: "abc")
    assert_equal MigratedLink::STATUS_RESOLVED, row.status
    assert_not_nil row.link_id
    assert_nil row.cached_until
    # record_success! reset the counters
    assert_equal 0, @source.reload.consecutive_failures
    assert_nil @source.first_failure_at
  end

  test "found outcome appends query string to redirect URL" do
    body = { "data" => { "$ios_url" => "myapp://ios" } }
    HTTParty.stub(:get, fake_response(code: 200, body: body)) do
      o = FirstHitMigration.call(source: @source, old_path: "abc", query_string: "utm=email")
      assert_match(/\?utm=email\z/, o.url)
    end
  end

  # ---------------------------------------------------------------------------
  # :not_found path
  # ---------------------------------------------------------------------------

  test "not_found outcome writes negative cache row + 24h TTL + record_success!" do
    @source.update_columns(consecutive_failures: 3, first_failure_at: 1.hour.ago)
    HTTParty.stub(:get, fake_response(code: 404, body: {})) do
      o = FirstHitMigration.call(source: @source, old_path: "typo")
      assert o.project_defaults?
    end
    row = MigratedLink.find_by(migration_source: @source, old_path: "typo")
    assert_equal MigratedLink::STATUS_NOT_FOUND, row.status
    assert_nil row.link_id
    assert_in_delta 24.hours.from_now.to_i, row.cached_until.to_i, 60
    # 404 counts as success — counters reset
    assert_equal 0, @source.reload.consecutive_failures
  end

  # ---------------------------------------------------------------------------
  # :transient_error path
  # ---------------------------------------------------------------------------

  test "transient_error writes row with backoff TTL + increments record_failure!" do
    HTTParty.stub(:get, fake_response(code: 500, body: {})) do
      o = FirstHitMigration.call(source: @source, old_path: "broken")
      assert o.project_defaults?
    end
    row = MigratedLink.find_by(migration_source: @source, old_path: "broken")
    assert_equal MigratedLink::STATUS_TRANSIENT_ERROR, row.status
    assert_not_nil row.cached_until
    assert_in_delta 5.seconds.from_now.to_i, row.cached_until.to_i, 5
    assert_equal 1, @source.reload.consecutive_failures
    assert_equal 500, @source.last_error_status
  end

  test "transient_error with retry_after uses that TTL" do
    HTTParty.stub(:get, fake_response(code: 429, body: {}, headers: { "retry-after" => "30" })) do
      FirstHitMigration.call(source: @source, old_path: "rl")
    end
    row = MigratedLink.find_by(migration_source: @source, old_path: "rl")
    assert_in_delta 30.seconds.from_now.to_i, row.cached_until.to_i, 5
  end

  # ---------------------------------------------------------------------------
  # backoff_for
  # ---------------------------------------------------------------------------

  test "backoff_for follows the 5/30/60/300/1800/3600 ladder, capped at 3600" do
    assert_equal 5,    FirstHitMigration.backoff_for(1)
    assert_equal 30,   FirstHitMigration.backoff_for(2)
    assert_equal 60,   FirstHitMigration.backoff_for(3)
    assert_equal 300,  FirstHitMigration.backoff_for(4)
    assert_equal 1800, FirstHitMigration.backoff_for(5)
    assert_equal 3600, FirstHitMigration.backoff_for(6)
    assert_equal 3600, FirstHitMigration.backoff_for(99)  # capped
  end

  # ---------------------------------------------------------------------------
  # SETNX single-flight (concurrency)
  #
  # Losers do NOT wait on the winner — they serve project defaults immediately. This
  # prevents thundering-herd thread-pool exhaustion (256 Puma threads pinned on a busy
  # poll loop during a campaign-blast burst on a hot slug would take the whole box down).
  # The trade-off: under simultaneous-burst on a fresh slug, the first cohort sees
  # project defaults instead of the actual deep link; clicks after the winner's row
  # lands serve correctly via the cache.
  # ---------------------------------------------------------------------------

  test "real concurrency: two threads racing on the same slug — exactly one upstream call" do
    body = { "data" => { "$ios_url" => "myapp://ios" } }
    upstream_calls = 0
    call_mutex = Mutex.new
    # Add a small artificial delay so both threads actually overlap inside the lock window
    HTTParty.stub(:get, lambda { |*|
      call_mutex.synchronize { upstream_calls += 1 }
      sleep 0.1
      fake_response(code: 200, body: body)
    }) do
      barrier = Queue.new
      threads = 2.times.map do
        Thread.new do
          barrier.pop  # park until released
          ActiveRecord::Base.connection_pool.with_connection do
            FirstHitMigration.call(source: @source, old_path: "race-test")
          end
        end
      end
      # Release both threads as close to simultaneously as possible
      2.times { barrier << :go }
      threads.each(&:join)
    end

    assert_equal 1, upstream_calls, "SETNX must dedupe — only the winner calls upstream"
    # Exactly one materialized Link, one cache row
    assert_equal 1, MigratedLink.where(migration_source: @source, old_path: "race-test").count
    assert_equal 1, Link.where(generated_from_platform: Grovs::Migrations::GENERATED_FROM_PLATFORM,
                               domain: @source.project.domain).where("name LIKE ?", "%branch%").count
  end

  test "loser does NOT call upstream when lock is held" do
    call_count = 0
    HTTParty.stub(:get, lambda { |*| 
      call_count += 1
      fake_response(code: 200, body: {})
    }) do
      lock_key = "migration:lock:#{@source.id}:#{Digest::SHA1.hexdigest('held')}"
      REDIS.with { |c| c.set(lock_key, "1", nx: true, ex: 10) }
      FirstHitMigration.call(source: @source, old_path: "held")
    end
    assert_equal 0, call_count, "loser must NOT call upstream while another worker holds the lock"
  end

  # ---------------------------------------------------------------------------
  # Per-source upstream rate limit (protects against scanner-driven quota exhaustion)
  # ---------------------------------------------------------------------------

  test "exceeding the per-source upstream rate limit serves project_defaults without calling upstream" do
    body = { "data" => { "$ios_url" => "myapp://ios" } }
    upstream_calls = 0
    HTTParty.stub(:get, lambda { |*| 
      upstream_calls += 1
      fake_response(code: 200, body: body)
    }) do
      # Pre-saturate the rate-limit bucket
      bucket = (Time.current.to_i / 60)
      key = "migration:upstream_rate:#{@source.id}:#{bucket}"
      REDIS.with { |c| c.set(key, FirstHitMigration::UPSTREAM_RATE_LIMIT_PER_MINUTE, ex: 65) }
      o = FirstHitMigration.call(source: @source, old_path: "rate-limited-slug")
      assert o.project_defaults?
      assert_equal 0, upstream_calls, "upstream must NOT be called past the per-source rate ceiling"
    end
  end

  test "rate limit releases the SETNX lock so other slugs can still resolve" do
    bucket = (Time.current.to_i / 60)
    key = "migration:upstream_rate:#{@source.id}:#{bucket}"
    REDIS.with { |c| c.set(key, FirstHitMigration::UPSTREAM_RATE_LIMIT_PER_MINUTE, ex: 65) }
    HTTParty.stub(:get, ->(*) { fake_response(code: 404, body: {}) }) do
      FirstHitMigration.call(source: @source, old_path: "rate-blocked")
    end
    # The lock for "rate-blocked" must have been released so a subsequent retry can re-enter.
    lock_key = "migration:lock:#{@source.id}:#{Digest::SHA1.hexdigest('rate-blocked')}"
    assert_nil REDIS.with { |c| c.get(lock_key) }, "lock should be released after rate-limit fast-fail"
  end

  test "loser returns project_defaults immediately (no blocking) when lock is held" do
    lock_key = "migration:lock:#{@source.id}:#{Digest::SHA1.hexdigest('immediate')}"
    REDIS.with { |c| c.set(lock_key, "1", nx: true, ex: 10) }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    o = FirstHitMigration.call(source: @source, old_path: "immediate")
    elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000

    assert o.project_defaults?
    assert elapsed_ms < 100, "loser took #{elapsed_ms.round}ms — should return in <100ms (no busy-poll on lock)"
  end

  # ---------------------------------------------------------------------------
  # Cache-staleness regression: upsert bypasses after_commit, so the explicit
  # MigratedLink.invalidate_cache_for call after each upsert is what prevents a
  # prior not_found row from masking a fresh resolved write.
  # ---------------------------------------------------------------------------

  test ":not_found upsert invalidates Redis so a subsequent :found upsert is visible" do
    # Seed a cached not_found result via a 404 upstream
    HTTParty.stub(:get, fake_response(code: 404, body: {})) do
      FirstHitMigration.call(source: @source, old_path: "stale")
    end
    # Confirm not_found is in cache
    cached_row = MigratedLink.redis_find_by_multiple_conditions(
      { migration_source_id: @source.id, old_path: "stale" }
    )
    assert_equal MigratedLink::STATUS_NOT_FOUND, cached_row.status

    # Clear the lock so the next call can re-enter the winner path
    REDIS.with { |c| c.del("migration:lock:#{@source.id}:#{Digest::SHA1.hexdigest('stale')}") }
    # Force the row TTL to be expired so the resolver falls through to FirstHitMigration
    MigratedLink.where(migration_source: @source, old_path: "stale").update_all(cached_until: 1.minute.ago)
    MigratedLink.invalidate_cache_for(migration_source_id: @source.id, old_path: "stale")

    # Now stub upstream to return a payload — upsert promotes the row to :resolved.
    body = { "data" => { "$ios_url" => "myapp://ios" } }
    HTTParty.stub(:get, fake_response(code: 200, body: body)) do
      FirstHitMigration.call(source: @source, old_path: "stale")
    end

    # The cache must reflect the :resolved row, not the prior :not_found
    fresh_row = MigratedLink.redis_find_by_multiple_conditions(
      { migration_source_id: @source.id, old_path: "stale" }
    )
    assert_equal MigratedLink::STATUS_RESOLVED, fresh_row.status,
      "Redis cache should reflect the fresh resolved row, not the prior not_found"
    assert_not_nil fresh_row.link_id
  end

  test "transient_error → resolved re-resolution preserves the original created_at" do
    # First call: 500 → row written as transient_error
    HTTParty.stub(:get, fake_response(code: 500, body: {})) do
      FirstHitMigration.call(source: @source, old_path: "preserve-ts")
    end
    original_created_at = MigratedLink.find_by(migration_source: @source, old_path: "preserve-ts").created_at

    # Expire the cache-until and clear the lock so the next call re-enters the winner path
    MigratedLink.where(migration_source: @source, old_path: "preserve-ts").update_all(cached_until: 1.minute.ago)
    REDIS.with { |c| c.del("migration:lock:#{@source.id}:#{Digest::SHA1.hexdigest('preserve-ts')}") }
    MigratedLink.invalidate_cache_for(migration_source_id: @source.id, old_path: "preserve-ts")

    sleep 0.05  # ensure later timestamps would differ if the bug returned

    # Second call: 200 → row promoted to resolved
    body = { "data" => { "$ios_url" => "myapp://ios" } }
    HTTParty.stub(:get, fake_response(code: 200, body: body)) do
      FirstHitMigration.call(source: @source, old_path: "preserve-ts")
    end

    row = MigratedLink.find_by(migration_source: @source, old_path: "preserve-ts")
    assert_equal MigratedLink::STATUS_RESOLVED, row.status
    assert_equal original_created_at.to_i, row.created_at.to_i,
      "created_at must be preserved across re-resolutions (UPSERT must use update_only)"
  end

  test "CAS-unlock: when our lock has expired and another worker holds it, our release is a no-op" do
    # Simulate the worst-case ownership scenario:
    #   1. Worker A acquires the lock
    #   2. A's processing exceeds LOCK_TTL — the lock auto-expires
    #   3. Worker B acquires (with a different token)
    #   4. A returns from upstream and runs its ensure block
    # The plain-DEL version would delete B's lock; the CAS-unlock must be a no-op.
    lock_key = "migration:lock:#{@source.id}:#{Digest::SHA1.hexdigest('cas-test')}"

    # Manually plant a "B" token, simulating that B took over the lock
    other_token = SecureRandom.hex(16)
    REDIS.with { |c| c.set(lock_key, other_token, ex: 60) }

    # A's stale token tries to release — must be ignored
    FirstHitMigration.release_lock(lock_key, "stale_a_token_doesnt_match")

    # B's lock value must still be present and unchanged
    still_held = REDIS.with { |c| c.get(lock_key) }
    assert_equal other_token, still_held, "CAS-unlock must not stomp another worker's lock"
  ensure
    REDIS.with { |c| c.del(lock_key) }
  end

  test "lock is released even when upstream raises (ensure block)" do
    HTTParty.stub(:get, ->(*) { raise "boom" }) do
      assert_raises(RuntimeError) do
        FirstHitMigration.call(source: @source, old_path: "boom")
      end
    end
    lock_key = "migration:lock:#{@source.id}:#{Digest::SHA1.hexdigest('boom')}"
    assert_nil REDIS.with { |c| c.get(lock_key) }, "lock should be released by ensure"
  end
end
