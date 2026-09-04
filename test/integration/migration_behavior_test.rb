require "test_helper"
require "sidekiq/testing"
require_relative "auth_test_helper"

class MigrationBehaviorTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :custom_hostnames, :applications,
           :ios_configurations, :android_configurations, :redirects

  setup do
    enable_migrations!
    REDIS.flushdb
    MigrationSource.delete_all
    MigratedLink.delete_all
    @project = projects(:one)
    @ch      = custom_hostnames(:acme_active)
    @ch.update_columns(status: "active")
    @source = MigrationSource.create!(
      project: @project, old_host: "links.acme.com",
      provider: "branch", credentials: { "branch_key" => "key_live_x" }
    )
    # Source cache is set on the way out; clear before tests use the resolver.
    @source.send(:invalidate_cache!)
  end
  teardown { disable_migrations! }

  def fake_branch(code:, body: nil, headers: {})
    Struct.new(:code, :parsed_response, :headers).new(code, body, headers)
  end

  # ---------------------------------------------------------------------------
  # Behavior #1: Happy path — first click materializes; second click hits cache.
  # ---------------------------------------------------------------------------

  test "first click on old host materializes Link + 301; second click hits cache (no upstream)" do
    body = { "data" => { "$ios_url" => "myapp://ios", "$og_title" => "Hello" } }
    upstream_calls = 0
    fake = lambda { |*| 
      upstream_calls += 1
      fake_branch(code: 200, body: body)
    }

    HTTParty.stub(:get, fake) do
      get "/somepath", headers: { "Host" => "links.acme.com" }
    end
    assert_response :moved_permanently
    assert_equal 1, upstream_calls

    link = MigratedLink.find_by(migration_source: @source, old_path: "somepath")&.link
    assert link, "expected materialized Link"
    # Redirect target is on the project's primary domain.
    assert_match link.access_path, response.headers["Location"]

    # Second click: cache hit, no upstream call.
    HTTParty.stub(:get, fake) do
      get "/somepath", headers: { "Host" => "links.acme.com" }
    end
    assert_response :moved_permanently
    assert_equal 1, upstream_calls, "second click must NOT call upstream"
  end

  test "first hit on a pending manual migration host is served, not 404, and enqueues activation" do
    enable_manual_custom_domains!
    ENV["MIGRATIONS_ENABLED"] = "true"
    @ch.update_columns(cf_custom_hostname_id: nil, status: "pending")
    @ch.reload.send(:clear_cache)

    body = { "data" => { "$ios_url" => "myapp://ios" } }
    Sidekiq::Testing.fake! do
      ActivateCustomHostnameJob.clear
      HTTParty.stub(:get, ->(*) { fake_branch(code: 200, body: body) }) do
        get "/firsthit", headers: { "Host" => "links.acme.com" }
      end
      assert_response :moved_permanently
      assert_equal 1, ActivateCustomHostnameJob.jobs.size
    end
    assert_equal "pending", @ch.reload.status, "activation is async — the request itself must not flip status"
  end

  # ---------------------------------------------------------------------------
  # Behavior: Query-string preservation in 301 target
  # ---------------------------------------------------------------------------

  test "query string is preserved in the 301 Location header" do
    body = { "data" => { "$ios_url" => "myapp://ios" } }
    HTTParty.stub(:get, ->(*) { fake_branch(code: 200, body: body) }) do
      get "/abc?utm_source=email&promo=spring", headers: { "Host" => "links.acme.com" }
    end
    assert_response :moved_permanently
    assert_includes response.headers["Location"], "utm_source=email&promo=spring"
  end

  # ---------------------------------------------------------------------------
  # Behavior: 404 from upstream → 24h negative cache, no Link materialized
  # ---------------------------------------------------------------------------

  test "404 upstream → no Link materialized, second click serves cache without upstream" do
    @project.redirect_config.update!(default_fallback: "https://acme.com")
    upstream_calls = 0
    HTTParty.stub(:get, lambda { |*| 
      upstream_calls += 1
      fake_branch(code: 404, body: {})
    }) do
      get "/missing", headers: { "Host" => "links.acme.com" }
    end
    row = MigratedLink.find_by(migration_source: @source, old_path: "missing")
    assert_equal MigratedLink::STATUS_NOT_FOUND, row.status
    assert_nil row.link_id

    # Second click: cache hit, no upstream call
    HTTParty.stub(:get, lambda { |*| 
      upstream_calls += 1
      fake_branch(code: 404, body: {})
    }) do
      get "/missing", headers: { "Host" => "links.acme.com" }
    end
    assert_equal 1, upstream_calls
  end

  # ---------------------------------------------------------------------------
  # Behavior: Migration disabled / source disabled / feature flag off → no resolution
  # ---------------------------------------------------------------------------

  test "feature flag off bypasses migration entirely" do
    disable_migrations!
    enable_custom_domains!  # keep TLS routing path alive
    # No upstream stub: if migration ran, HTTParty would actually hit the network. The
    # response should be the existing 404 path (or any non-migration result), not a 301.
    get "/somepath", headers: { "Host" => "links.acme.com" }
    assert_not_equal 301, response.status
    assert_not_equal 302, response.status
    assert_equal 0, MigratedLink.count
  end

  test "disabled source: uncached click does NOT first-hit upstream and does NOT materialize" do
    @source.update!(enabled: false)
    @source.send(:invalidate_cache!)
    HTTParty.stub(:get, ->(*) { raise "must not call upstream when disabled" }) do
      get "/uncached-abc", headers: { "Host" => "links.acme.com" }
    end
    assert_equal 0, MigratedLink.count
  end

  test "disabled source: PREVIOUSLY-cached resolved row still serves the 301" do
    # Regression for the auto-disable-breaks-existing-links bug. Materialize a Link while
    # the source is enabled, then disable it. Subsequent clicks on the cached slug must
    # still redirect — disable only stops NEW upstream resolution.
    link = MigratedLinkBuilder.call(project: @project, payload: { "ios_url" => "myapp://ios", "provider" => "branch" })
    MigratedLink.create!(
      migration_source: @source, link: link, old_path: "cached-then-disabled",
      status: MigratedLink::STATUS_RESOLVED, cached_until: nil
    )
    MigratedLink.invalidate_cache_for(migration_source_id: @source.id, old_path: "cached-then-disabled")
    @source.update!(enabled: false)
    @source.send(:invalidate_cache!)

    HTTParty.stub(:get, ->(*) { raise "must not call upstream — row is cached" }) do
      get "/cached-then-disabled", headers: { "Host" => "links.acme.com" }
    end
    assert_response :moved_permanently
  end

  # ---------------------------------------------------------------------------
  # Behavior: Host normalization — uppercase/port still finds the source
  # ---------------------------------------------------------------------------

  # End-to-end through the actual lifecycle: when CustomDomainLifecycleJob suspends the
  # CustomHostname, a migrated click on that host MUST stop redirecting and stop calling
  # upstream — even for slugs that were already resolved + cached before the suspension.
  test "lifecycle suspends hostname → migrated click does not redirect and does not call upstream" do
    # Set up a cached resolved row so the suspension can't be argued away by "fresh slug".
    link = MigratedLinkBuilder.call(
      project: @project,
      payload: { "ios_url" => "myapp://ios", "provider" => "branch" }
    )
    MigratedLink.create!(
      migration_source: @source, link: link, old_path: "post-teardown",
      status: MigratedLink::STATUS_RESOLVED, cached_until: nil
    )
    MigratedLink.invalidate_cache_for(migration_source_id: @source.id, old_path: "post-teardown")

    # Sanity: while CH is active, the click DOES 301.
    HTTParty.stub(:get, ->(*) { raise "must not call upstream — row is cached" }) do
      get "/post-teardown", headers: { "Host" => "links.acme.com" }
    end
    assert_response :moved_permanently

    # Simulate the lifecycle teardown step that suspends the hostname.
    # (CustomDomainLifecycleJob#process_active flips status to "suspended" then calls
    # finalize_teardown; we exercise just the status transition that affects routing.)
    @ch.update!(status: "suspended")
    REDIS.with { |c| c.del("custom_hostnames:find_by:hostname:#{@ch.hostname}:no_includes") }

    # After suspension: no 301, no upstream call, no project_defaults redirect either —
    # migration resolution returns nil so the request falls through to the existing 404 path.
    HTTParty.stub(:get, ->(*) { raise "must not call upstream — host is decommissioned" }) do
      get "/post-teardown", headers: { "Host" => "links.acme.com" }
    end
    assert_not_equal 301, response.status
    assert_not_equal 302, response.status
  end

  test "uppercase Host header still resolves the same source" do
    body = { "data" => { "$ios_url" => "myapp://ios" } }
    HTTParty.stub(:get, ->(*) { fake_branch(code: 200, body: body) }) do
      get "/upper", headers: { "Host" => "Links.Acme.COM" }
    end
    assert_response :moved_permanently
    assert_not_nil MigratedLink.find_by(migration_source: @source, old_path: "upper")
  end
end
