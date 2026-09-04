require "test_helper"

class MigrationResolverTest < ActiveSupport::TestCase
  include MigrationFixtureHelpers

  fixtures :projects, :instances, :domains, :redirect_configs, :custom_hostnames,
           :migration_sources, :migrated_links, :links

  setup do
    REDIS.flushdb
    @source = migration_sources(:acme_branch)
    @project = @source.project
    enable_migrations!

    reset_acme_active_to_active!

    @source.update!(credentials: { "branch_key" => "k" })
    @source.send(:invalidate_cache!)
    MigratedLink.where(migration_source: @source).pluck(:old_path).each do |path|
      MigratedLink.invalidate_cache_for(migration_source_id: @source.id, old_path: path)
    end
  end

  teardown { disable_migrations! }

  test "returns nil when migrations feature flag is off" do
    disable_migrations!
    assert_nil MigrationResolver.resolve("links.acme.com", "abc")
  end

  test "returns nil for unknown host" do
    assert_nil MigrationResolver.resolve("nobody.example.com", "abc")
  end

  test "disabled source: cache miss returns nil (no first-hit upstream call)" do
    @source.update!(enabled: false)
    @source.send(:invalidate_cache!)
    FirstHitMigration.stub(:call, ->(*) { raise "must not first-hit when disabled" }) do
      assert_nil MigrationResolver.resolve("links.acme.com", "uncached-slug")
    end
  end

  test "disabled source: cached resolved row STILL redirects (no upstream needed)" do
    row = migrated_links(:acme_resolved)
    @source.update!(enabled: false)
    @source.send(:invalidate_cache!)
    FirstHitMigration.stub(:call, ->(*) { raise "must not first-hit when disabled" }) do
      outcome = MigrationResolver.resolve("links.acme.com", row.old_path)
      assert outcome&.redirect?, "cached resolved row must keep redirecting through a disable"
      assert_equal row.link, outcome.link
    end
  end

  test "disabled source: cached not_found row still serves project_defaults (no upstream needed)" do
    row = migrated_links(:acme_not_found_fresh)
    @source.update!(enabled: false)
    @source.send(:invalidate_cache!)
    FirstHitMigration.stub(:call, ->(*) { raise "must not first-hit when disabled" }) do
      outcome = MigrationResolver.resolve("links.acme.com", row.old_path)
      assert outcome&.project_defaults?, "cached not_found still serves project defaults under disable"
    end
  end

  test "returns nil when the matching CustomHostname is no longer active" do
    ch = custom_hostnames(:acme_active)
    ch.update!(status: "suspended")
    FirstHitMigration.stub(:call, ->(*) { raise "must not be called when CH inactive" }) do
      assert_nil MigrationResolver.resolve("links.acme.com", "abc")
    end
  ensure
    ch&.update!(status: "active")
  end

  test "cached resolved row is NOT served when CustomHostname is suspended" do
    row = migrated_links(:acme_resolved)
    assert_equal MigratedLink::STATUS_RESOLVED, row.status, "fixture sanity check"
    assert_not_nil row.link_id, "fixture sanity check"

    ch = custom_hostnames(:acme_active)
    ch.update!(status: "suspended")

    FirstHitMigration.stub(:call, ->(*) { raise "must not call upstream on a cached hit" }) do
      assert_nil MigrationResolver.resolve("links.acme.com", row.old_path),
        "cached resolved redirect must NOT be served once the CustomHostname is suspended"
    end
  ensure
    ch&.update!(status: "active")
  end

  test "cached not_found is also blocked when CustomHostname is suspended" do
    row = migrated_links(:acme_not_found_fresh)
    ch = custom_hostnames(:acme_active)
    ch.update!(status: "suspended")

    FirstHitMigration.stub(:call, ->(*) { raise "must not call upstream on a cached hit" }) do
      assert_nil MigrationResolver.resolve("links.acme.com", row.old_path)
    end
  ensure
    ch&.update!(status: "active")
  end

  test "returns nil when the CustomHostname now belongs to a different project" do
    ch = custom_hostnames(:acme_active)
    other_project = projects(:two)
    ch.update!(project_id: other_project.id, domain_id: (other_project.domain || domains(:two)).id)
    FirstHitMigration.stub(:call, ->(*) { raise "must not be called on cross-project CH" }) do
      assert_nil MigrationResolver.resolve("links.acme.com", "abc")
    end
  ensure
    ch&.update!(project_id: @source.project_id, domain_id: domains(:one).id)
  end

  test "returns nil when no matching CustomHostname row exists" do
    custom_hostnames(:acme_active).destroy
    FirstHitMigration.stub(:call, ->(*) { raise "must not be called without CH" }) do
      assert_nil MigrationResolver.resolve("links.acme.com", "abc")
    end
  end

  # Manual rows cannot be active before cutover, so the first hit itself is the proof.
  test "custom_hostname_still_active?: a pending manual row resolves on its first hit" do
    ch = custom_hostnames(:acme_active)
    ch.update_columns(cf_custom_hostname_id: nil, status: "pending")
    ch.reload.send(:clear_cache)

    assert MigrationResolver.custom_hostname_still_active?(@source, "links.acme.com")
  end

  test "custom_hostname_still_active?: a pending cloudflare row does not resolve" do
    ch = custom_hostnames(:acme_active)
    ch.update_columns(cf_custom_hostname_id: "cf_1", status: "pending")
    ch.reload.send(:clear_cache)

    assert_not MigrationResolver.custom_hostname_still_active?(@source, "links.acme.com")
  end

  test "custom_hostname_still_active?: a suspended manual row does not resolve" do
    ch = custom_hostnames(:acme_active)
    ch.update_columns(cf_custom_hostname_id: nil, status: "suspended")
    ch.reload.send(:clear_cache)

    assert_not MigrationResolver.custom_hostname_still_active?(@source, "links.acme.com")
  end

  test "a first hit on a pending manual row enqueues its activation" do
    require "sidekiq/testing"
    ch = custom_hostnames(:acme_active)
    ch.update_columns(cf_custom_hostname_id: nil, status: "pending")
    ch.reload.send(:clear_cache)

    Sidekiq::Testing.fake! do
      ActivateCustomHostnameJob.clear
      MigrationResolver.custom_hostname_still_active?(@source, "links.acme.com")
      assert_equal 1, ActivateCustomHostnameJob.jobs.size
      assert_equal ch.id, ActivateCustomHostnameJob.jobs.first["args"].first
    end
  end

  test "an already active row enqueues nothing" do
    require "sidekiq/testing"
    Sidekiq::Testing.fake! do
      ActivateCustomHostnameJob.clear
      MigrationResolver.custom_hostname_still_active?(@source, "links.acme.com")
      assert_equal 0, ActivateCustomHostnameJob.jobs.size
    end
  end

  test "custom_hostname_still_active?: primary-purpose CustomHostname returns false" do
    # purpose is attr_readonly; raw SQL simulates a row that bypassed the validator.
    ch = custom_hostnames(:acme_active)
    CustomHostname.where(id: ch.id).update_all(purpose: Grovs::Hostnames::PURPOSE_PRIMARY)
    ch.reload
    ch.send(:clear_cache)
    assert_not MigrationResolver.custom_hostname_still_active?(@source, "links.acme.com")
  ensure
    if ch
      CustomHostname.where(id: ch.id).update_all(purpose: Grovs::Hostnames::PURPOSE_MIGRATION)
      ch.reload.send(:clear_cache)
    end
  end

  test "custom_hostname_still_active?: migration-purpose + active returns true" do
    assert MigrationResolver.custom_hostname_still_active?(@source, "links.acme.com")
  end

  # Pins the validator-relaxation contract: MigrationSource#custom_hostname_exists_for_project
  # accepts a pending CH at create time (so POST /migrations can atomically provision CH + source
  # in one txn). The runtime resolver MUST reject pending — otherwise migration traffic could be
  # served against a CH whose SSL isn't issued yet.
  test "custom_hostname_still_active?: migration-purpose + pending status returns false" do
    ch = custom_hostnames(:acme_active)
    ch.update!(status: "pending")
    assert_not MigrationResolver.custom_hostname_still_active?(@source, "links.acme.com")
  ensure
    ch&.update!(status: "active")
  end

  test "custom_hostname_still_active?: cross-project CustomHostname returns false" do
    ch = custom_hostnames(:acme_active)
    other_project = projects(:two)
    ch.update!(project_id: other_project.id,
               domain_id: (other_project.domain || domains(:two)).id)
    assert_not MigrationResolver.custom_hostname_still_active?(@source, "links.acme.com")
  ensure
    ch&.update!(project_id: @source.project_id, domain_id: domains(:one).id)
  end

  test "resolve returns nil when matching CustomHostname purpose is primary (bad-data defense)" do
    row = migrated_links(:acme_resolved)
    ch = custom_hostnames(:acme_active)
    CustomHostname.where(id: ch.id).update_all(purpose: Grovs::Hostnames::PURPOSE_PRIMARY)
    ch.reload
    ch.send(:clear_cache)
    FirstHitMigration.stub(:call, ->(*) { raise "must not first-hit when CH is primary" }) do
      assert_nil MigrationResolver.resolve("links.acme.com", row.old_path)
    end
  ensure
    if ch
      CustomHostname.where(id: ch.id).update_all(purpose: Grovs::Hostnames::PURPOSE_MIGRATION)
      ch.reload.send(:clear_cache)
    end
  end

  test "normalizes incoming host (case, port, trailing dot)" do
    FirstHitMigration.stub(:call, ->(**) { MigrationOutcome.project_defaults(@project) }) do
      o = MigrationResolver.resolve("Links.Acme.COM:443.", "abc")
      assert o.project_defaults?
    end
  end

  test "cached resolved row returns redirect outcome (no upstream)" do
    row = migrated_links(:acme_resolved)
    FirstHitMigration.stub(:call, ->(*) { raise "must not be called" }) do
      o = MigrationResolver.resolve("links.acme.com", row.old_path)
      assert o.redirect?
      assert_equal row.link, o.link
    end
  end

  test "cached resolved redirect preserves query string in URL" do
    row = migrated_links(:acme_resolved)
    o = MigrationResolver.resolve("links.acme.com", row.old_path, query_string: "utm_source=email")
    assert_match(/\?utm_source=email\z/, o.url)
  end

  test "cached fresh not_found returns project defaults (no upstream)" do
    row = migrated_links(:acme_not_found_fresh)
    FirstHitMigration.stub(:call, ->(*) { raise "must not be called" }) do
      o = MigrationResolver.resolve("links.acme.com", row.old_path)
      assert o.project_defaults?
    end
  end

  test "cached expired not_found falls through to FirstHitMigration" do
    row = migrated_links(:acme_not_found_fresh)
    row.update!(cached_until: 1.minute.ago)
    called = false
    FirstHitMigration.stub(:call, lambda { |**| 
      called = true
      MigrationOutcome.project_defaults(@project)
    }) do
      MigrationResolver.resolve("links.acme.com", row.old_path)
    end
    assert called, "expected fall-through to FirstHitMigration"
  end

  test "cached fresh transient_error returns project defaults (does NOT call upstream)" do
    MigratedLink.create!(
      migration_source: @source, old_path: "transient",
      status: MigratedLink::STATUS_TRANSIENT_ERROR, cached_until: 5.minutes.from_now
    )
    FirstHitMigration.stub(:call, ->(*) { raise "must not be called" }) do
      o = MigrationResolver.resolve("links.acme.com", "transient")
      assert o.project_defaults?, "fresh transient_error must serve project defaults"
    end
  end

  test "expected_project guard rejects cross-tenant resolution" do
    other = projects(:two)
    FirstHitMigration.stub(:call, ->(*) { raise "must not be called for wrong project" }) do
      assert_nil MigrationResolver.resolve("links.acme.com", "abc", expected_project: other)
    end
  end

  test "expected_project guard allows same-project resolution" do
    row = migrated_links(:acme_resolved)
    o = MigrationResolver.resolve("links.acme.com", row.old_path, expected_project: @project)
    assert o.redirect?
  end

  test "orphaned resolved row (link_id nil after admin Link.destroy) serves project defaults — does NOT re-resolve" do
    row = migrated_links(:acme_resolved)
    MigratedLink.where(id: row.id).update_all(link_id: nil)
    MigratedLink.invalidate_cache_for(migration_source_id: row.migration_source_id, old_path: row.old_path)

    FirstHitMigration.stub(:call, ->(*) { raise "must not re-resolve an admin-deleted Link" }) do
      outcome = MigrationResolver.resolve("links.acme.com", row.old_path)
      assert outcome.project_defaults?, "expected project_defaults for orphan resolved row"
    end
  end

  test "Shape 1 — full https URL: host-based MigrationSource lookup resolves" do
    row = migrated_links(:acme_resolved)
    outcome = MigrationResolver.resolve_from_sdk(
      "https://links.acme.com/#{row.old_path}?utm=x",
      expected_project: @project
    )
    assert outcome&.redirect?
  end

  test "Shape 1 — http URL on an unknown host returns nil (does NOT fall through to project source)" do
    FirstHitMigration.stub(:call, ->(*) { raise "must not first-hit for unknown host" }) do
      assert_nil MigrationResolver.resolve_from_sdk(
        "https://unrelated.example.com/abc123",
        expected_project: @project
      )
    end
  end

  test "Shape 1 — blank/nil/whitespace input returns nil" do
    assert_nil MigrationResolver.resolve_from_sdk(nil, expected_project: @project)
    assert_nil MigrationResolver.resolve_from_sdk("", expected_project: @project)
    assert_nil MigrationResolver.resolve_from_sdk("   ", expected_project: @project)
  end

  test "Shape 1 — feature flag off returns nil" do
    disable_migrations!
    assert_nil MigrationResolver.resolve_from_sdk(
      "https://links.acme.com/whatever",
      expected_project: @project
    )
  end

  test "Shape 2 — Install Referrer with Branch's ~referring_link resolves the embedded URL" do
    row = migrated_links(:acme_resolved)
    embedded = "https://links.acme.com/#{row.old_path}"
    referrer = "utm_source=google&utm_campaign=spring&" \
               "~referring_link=#{ERB::Util.url_encode(embedded)}"

    outcome = MigrationResolver.resolve_from_sdk(referrer, expected_project: @project)
    assert outcome&.redirect?, "Branch ~referring_link must drive migration resolution"
  end

  test "Shape 2 — AppsFlyer-style referrer (no ~referring_link) returns nil — fingerprint fallback at caller" do
    referrer = "pid=googleadwords_int&c=spring_campaign&af_siteid=site123&af_click_lookback=7d"
    assert_nil MigrationResolver.resolve_from_sdk(referrer, expected_project: @project)
  end

  test "Shape 2 — ~referring_link pointing at unknown host returns nil" do
    referrer = "~referring_link=#{ERB::Util.url_encode('https://nobody.example.com/x')}"
    assert_nil MigrationResolver.resolve_from_sdk(referrer, expected_project: @project)
  end

  test "Shape 2 — ~referring_link that is not itself a URL returns nil (no recursion)" do
    referrer = "~referring_link=#{ERB::Util.url_encode('not-a-url')}"
    assert_nil MigrationResolver.resolve_from_sdk(referrer, expected_project: @project)
  end

  test "Shape 2 — malformed %-encoding in referrer returns nil (no crash)" do
    referrer = "key=value&malformed=%ZZ"
    assert_nil MigrationResolver.resolve_from_sdk(referrer, expected_project: @project)
  end

  test "Shape 2 — ~referring_link still respects the cross-project guard" do
    row = migrated_links(:acme_resolved)
    embedded = "https://links.acme.com/#{row.old_path}"
    referrer = "~referring_link=#{ERB::Util.url_encode(embedded)}"

    FirstHitMigration.stub(:call, ->(*) { raise "must not first-hit under wrong project" }) do
      assert_nil MigrationResolver.resolve_from_sdk(referrer, expected_project: projects(:two))
    end
  end

  test "Shape 3 — custom-scheme deep link (myapp://slug) resolves via the project's MigrationSource" do
    row = migrated_links(:acme_resolved)
    outcome = MigrationResolver.resolve_from_sdk(
      "myapp://#{row.old_path}",
      expected_project: @project
    )
    assert outcome&.redirect?
  end

  test "Shape 3 — bare slug resolves via the project's MigrationSource" do
    row = migrated_links(:acme_resolved)
    outcome = MigrationResolver.resolve_from_sdk(row.old_path, expected_project: @project)
    assert outcome&.redirect?
  end

  test "Shape 3 — multi-segment custom-scheme path preserved" do
    row = migrated_links(:acme_resolved)
    FirstHitMigration.stub(:call, lambda { |source:, query_string:, **|
      MigrationOutcome.redirect(links(:basic_link), query_string: query_string, provider: source.provider)
    }) do
      outcome = MigrationResolver.resolve_from_sdk(
        "myapp://something/#{row.old_path}",
        expected_project: @project
      )
      assert outcome&.redirect?
    end
  end

  test "Shape 3 — custom-scheme with no slug component returns nil" do
    assert_nil MigrationResolver.resolve_from_sdk("myapp://", expected_project: @project)
  end

  test "Shape 3 — project with no MigrationSource returns nil" do
    other = projects(:two) # no migration_source
    assert_nil other.migration_source, "fixture setup precondition"
    assert_nil MigrationResolver.resolve_from_sdk("abc123", expected_project: other)
  end

  test "Shape 3 — slug fallback still respects the cross-project guard" do
    assert_nil MigrationResolver.resolve_from_sdk("resolved-abc", expected_project: projects(:two))
  end

  def create_provider_hosted_source!
    ENV["GROVS_SELF_HOSTED"] = "true"
    MigrationSource.create!(
      project: projects(:two), old_host: "xyz.app.link",
      provider: Grovs::Migrations::PROVIDER_BRANCH,
      credentials: { "branch_key" => "k" },
      provider_hosted: true, extra_hosts: ["xyz-alternate.app.link"]
    )
  end

  test "provider_hosted source resolves with NO CustomHostname row" do
    source = create_provider_hosted_source!
    assert_nil CustomHostname.redis_find_by(:hostname, "xyz.app.link")

    sentinel = Object.new
    FirstHitMigration.stub(:call, ->(source:, old_path:, query_string:) { sentinel }) do
      assert_same sentinel, MigrationResolver.resolve("xyz.app.link", "abc")
    end
  ensure
    source&.destroy
  end

  test "extra host resolves to the SAME source and cache key with expected_project" do
    source = create_provider_hosted_source!
    calls = []
    sentinel = Object.new
    stub = lambda do |source:, old_path:, query_string:|
      calls << [source.id, old_path]
      sentinel
    end
    FirstHitMigration.stub(:call, stub) do
      assert_same sentinel,
                  MigrationResolver.resolve("xyz.app.link", "abc", expected_project: projects(:two))
      assert_same sentinel,
                  MigrationResolver.resolve("xyz-alternate.app.link", "abc", expected_project: projects(:two))
    end
    assert_equal [[source.id, "abc"], [source.id, "abc"]], calls
  ensure
    source&.destroy
  end

  test "extra host without expected_project returns nil (no global lookup for extras)" do
    source = create_provider_hosted_source!
    FirstHitMigration.stub(:call, ->(*) { raise "must not resolve extra host without project context" }) do
      assert_nil MigrationResolver.resolve("xyz-alternate.app.link", "abc")
    end
  ensure
    source&.destroy
  end

  test "extra host does not resolve when GROVS_SELF_HOSTED is off" do
    source = create_provider_hosted_source!
    ENV.delete("GROVS_SELF_HOSTED")
    FirstHitMigration.stub(:call, ->(*) { raise "extra hosts must not resolve off self-hosted" }) do
      assert_nil MigrationResolver.resolve("xyz-alternate.app.link", "abc", expected_project: projects(:two))
    end
  ensure
    source&.destroy
  end

  test "extra host with WRONG expected_project returns nil" do
    source = create_provider_hosted_source!
    FirstHitMigration.stub(:call, ->(*) { raise "cross-tenant leak" }) do
      assert_nil MigrationResolver.resolve("xyz-alternate.app.link", "abc", expected_project: projects(:one))
    end
  ensure
    source&.destroy
  end

  test "resolve_from_sdk resolves an extra-host URL" do
    source = create_provider_hosted_source!
    sentinel = Object.new
    FirstHitMigration.stub(:call, ->(source:, old_path:, query_string:) { sentinel }) do
      assert_same sentinel, MigrationResolver.resolve_from_sdk(
        "https://xyz-alternate.app.link/abc?x=1", expected_project: projects(:two)
      )
    end
  ensure
    source&.destroy
  end
end
