require "test_helper"

class CustomDomainProvisioningServiceTest < ActiveSupport::TestCase
  fixtures :instances, :users, :projects, :domains, :stripe_payment_intents, :stripe_subscriptions

  setup do
    enable_custom_domains!
    REDIS.flushdb
    CustomHostname.delete_all
    EnterpriseSubscription.delete_all
  end
  teardown { disable_custom_domains! }

  test "create reserves the row then provisions at Cloudflare" do
    CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_new", status: "pending", ssl_status: "pending_validation" }) do
      result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.acmeco.com")
      assert result.ok
      ch = result.custom_hostname
      assert_equal "pending", ch.status
      assert_equal "cf_new", ch.cf_custom_hostname_id
      assert_equal "saas", ch.source
    end
  end

  test "self-serve create remains saas even when enterprise entitlement is active" do
    StripeSubscription.where(instance_id: instances(:two).id).delete_all
    EnterpriseSubscription.create!(
      instance: instances(:two),
      start_date: 1.day.ago,
      end_date: 1.year.from_now,
      total_maus: 10_000,
      active: true
    )
    project = Project.find(projects(:two).id)
    assert project.instance.custom_domains_entitled?

    CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_self_serve", status: "pending", ssl_status: "pending_validation" }) do
      result = CustomDomainProvisioningService.create(project: project, hostname: "links.enterprise-self-serve.com")
      assert result.ok
      assert_equal "saas", result.custom_hostname.source
    end
  end

  test "create requires entitlement and makes no Cloudflare call" do
    called = false
    CloudflareCustomHostnameService.stub(:create, ->(**) { called = true }) do
      result = CustomDomainProvisioningService.create(project: projects(:two), hostname: "links.newco.com")
      assert_not result.ok
      assert_equal :payment_required, result.status
    end
    assert_not called
    assert_not CustomHostname.exists?(hostname: "links.newco.com")
  end

  test "create rejects an unavailable hostname (apex)" do
    result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "acmeco.com")
    assert_not result.ok
    assert_equal :unprocessable_entity, result.status
  end

  test "create compensates by removing the reserved row when Cloudflare fails" do
    CloudflareCustomHostnameService.stub(:create, { success: false, error: "cf down" }) do
      CloudflareCustomHostnameService.stub(:lookup, { success: false }) do
        result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.acmeco.com")
        assert_not result.ok
        assert_equal :bad_gateway, result.status
      end
    end
    assert_not CustomHostname.exists?(hostname: "links.acmeco.com")
  end

  test "create rejects a second custom domain for the same project (conflict)" do
    CustomHostname.create!(project: projects(:one), domain: domains(:one), hostname: "links.first.com", status: "active", source: "saas")
    result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.second.com")
    assert_not result.ok
    assert_equal :conflict, result.status
  end

  test "destroy removes Cloudflare and the row on success, reverting branding" do
    ch = CustomHostname.create!(project: projects(:one), domain: domains(:one),
                                hostname: "links.del.com", cf_custom_hostname_id: "cf_d",
                                status: "active", source: "saas")
    domains(:one).update!(active_custom_host: "links.del.com")
    CloudflareCustomHostnameService.stub(:delete, true) do
      assert CustomDomainProvisioningService.destroy(ch)
    end
    assert_not CustomHostname.exists?(ch.id)
    assert_nil domains(:one).reload.active_custom_host
  end

  test "a hostname is available again after teardown hard-deletes it (no squatting)" do
    ch = CustomHostname.create!(project: projects(:one), domain: domains(:one),
                                hostname: "links.reuse.com", cf_custom_hostname_id: "cf_r",
                                status: "active", source: "saas")
    assert_not DomainConfigurationService.custom_hostname_available?("links.reuse.com")
    CloudflareCustomHostnameService.stub(:delete, true) do
      assert CustomDomainProvisioningService.destroy(ch)
    end
    assert DomainConfigurationService.custom_hostname_available?("links.reuse.com")
  end

  test "create fails (compensating delete) when Cloudflare returns success without a cf id" do
    CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: nil, status: "pending" }) do
      CloudflareCustomHostnameService.stub(:lookup, { success: false }) do
        result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.acmeco.com")
        assert_not result.ok
        assert_equal :bad_gateway, result.status
      end
    end
    assert_not CustomHostname.exists?(hostname: "links.acmeco.com")
  end

  test "destroy keeps the row but reverts branding when Cloudflare delete fails" do
    ch = CustomHostname.create!(project: projects(:one), domain: domains(:one),
                                hostname: "links.del.com", cf_custom_hostname_id: "cf_d",
                                status: "active", source: "saas")
    domains(:one).update!(active_custom_host: "links.del.com")
    CloudflareCustomHostnameService.stub(:delete, false) do
      assert_not CustomDomainProvisioningService.destroy(ch)
    end
    assert CustomHostname.exists?(ch.id)
    ch.reload
    assert_equal "suspended", ch.status
    assert_not ch.resolvable?, "must stop resolving immediately even when CF delete fails"
    assert_nil domains(:one).reload.active_custom_host
  end

  test "create maps a concurrent unique-index collision to :conflict" do
    CustomHostname.create!(project: projects(:one), domain: domains(:one),
                           hostname: "links.winner.com", status: "active", source: "saas")

    # Stubbing the precheck relation to empty reproduces the race-window the rescue covers.
    projects(:one).stub(:custom_hostnames, CustomHostname.where("1 = 0")) do
      result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.loser.com")
      assert_not result.ok
      assert_equal :conflict, result.status
    end

    assert_not CustomHostname.exists?(hostname: "links.loser.com")
    assert_equal 1, CustomHostname.where(project: projects(:one)).count
  end

  test "create rejects a raw Unicode (IDN) hostname with a clear message, no Cloudflare call" do
    called = false
    CloudflareCustomHostnameService.stub(:create, ->(**) { called = true }) do
      result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "münchen.example.com")
      assert_not result.ok
      assert_equal :unprocessable_entity, result.status
      assert_match(/ascii|punycode/i, result.error)
    end
    assert_not called
    assert_not CustomHostname.exists?(hostname: "münchen.example.com")
  end

  test "create reaps a prior failed attempt so a retry is not blocked by the dead row" do
    CustomHostname.create!(project: projects(:one), domain: domains(:one),
                           hostname: "links.old.com", cf_custom_hostname_id: "cf_old",
                           status: "failed", source: "saas")

    CloudflareCustomHostnameService.stub(:delete, true) do
      CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_new", status: "pending", ssl_status: "pending_validation" }) do
        result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.new.com")
        assert result.ok, "a failed row must not lock the project's slot"
        assert_equal "pending", result.custom_hostname.status
      end
    end

    assert_not CustomHostname.exists?(hostname: "links.old.com"), "the failed row is reaped"
    assert CustomHostname.exists?(hostname: "links.new.com")
    assert_equal 1, CustomHostname.where(project: projects(:one)).count
  end

  test "create can re-provision the exact same hostname after a prior failure" do
    CustomHostname.create!(project: projects(:one), domain: domains(:one),
                           hostname: "links.same.com", cf_custom_hostname_id: "cf_old",
                           status: "failed", source: "saas")

    CloudflareCustomHostnameService.stub(:delete, true) do
      CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_fresh", status: "pending", ssl_status: "pending_validation" }) do
        result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.same.com")
        assert result.ok, "the customer's own failed row must not make the hostname 'unavailable'"
        assert_equal "cf_fresh", result.custom_hostname.cf_custom_hostname_id
      end
    end
    assert_equal 1, CustomHostname.where(hostname: "links.same.com").count
  end

  test "create adopts an existing Cloudflare hostname when create reports it already exists" do
    CloudflareCustomHostnameService.stub(:create, { success: false, error: "already exists" }) do
      CloudflareCustomHostnameService.stub(:lookup, { success: true, cf_id: "cf_orphan", status: "pending", ssl_status: "pending_validation" }) do
        result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.orphan.com")
        assert result.ok, "must adopt a Cloudflare hostname orphaned by a crashed create"
        assert_equal "cf_orphan", result.custom_hostname.cf_custom_hostname_id
        assert_equal "pending", result.custom_hostname.status
      end
    end
    assert CustomHostname.exists?(hostname: "links.orphan.com")
  end

  test "destroy reports success when the row was already removed (lost the race to teardown)" do
    ch = CustomHostname.create!(project: projects(:one), domain: domains(:one),
                                hostname: "links.gone.com", cf_custom_hostname_id: "cf_g",
                                status: "active", source: "saas")
    CustomHostname.where(id: ch.id).delete_all

    CloudflareCustomHostnameService.stub(:delete, true) do
      assert CustomDomainProvisioningService.destroy(ch), "an already-removed row is the desired end state, not a 500"
    end
  end

  test "destroy suspends the row before the Cloudflare delete (crash-safety)" do
    ch = CustomHostname.create!(project: projects(:one), domain: domains(:one),
                                hostname: "links.crashsafe.com", cf_custom_hostname_id: "cf_cs",
                                status: "active", source: "saas")
    status_when_cf_called = nil
    capture_status = lambda do |**|
      status_when_cf_called = ch.status
      true
    end
    CloudflareCustomHostnameService.stub(:delete, capture_status) do
      CustomDomainProvisioningService.destroy(ch)
    end
    assert_equal "suspended", status_when_cf_called,
                 "row must be non-resolvable before the CF delete, so a crash mid-teardown can't leave it active"
  end

  test "create maps a model uniqueness validation failure to :conflict (not a 500)" do
    CustomHostname.create!(project: projects(:two), domain: domains(:two),
                           hostname: "links.shared.com", status: "active", source: "saas")
    DomainConfigurationService.stub(:custom_hostname_available?, true) do
      result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.shared.com")
      assert_not result.ok
      assert_equal :conflict, result.status
    end
  end

  test "create accepts an explicit migration purpose and persists it on the row" do
    CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_mig", status: "pending", ssl_status: "pending_validation" }) do
      result = CustomDomainProvisioningService.create(
        project: projects(:one), hostname: "old-branch.acmeco.com",
        purpose: Grovs::Hostnames::PURPOSE_MIGRATION
      )
      assert result.ok
      assert_equal Grovs::Hostnames::PURPOSE_MIGRATION, result.custom_hostname.purpose
      assert result.custom_hostname.migration?
    end
  end

  test "create rejects an unknown purpose with :unprocessable_entity and creates no row" do
    called = false
    CloudflareCustomHostnameService.stub(:create, ->(**) { called = true }) do
      result = CustomDomainProvisioningService.create(
        project: projects(:one), hostname: "links.acmeco.com", purpose: "bogus"
      )
      assert_not result.ok
      assert_equal :unprocessable_entity, result.status
      assert_equal "Invalid purpose", result.error
    end
    assert_not called
    assert_not CustomHostname.exists?(hostname: "links.acmeco.com")
  end

  test "primary and migration coexist on the same project" do
    CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_p", status: "pending", ssl_status: "pending_validation" }) do
      primary = CustomDomainProvisioningService.create(
        project: projects(:one), hostname: "primary.acme.com",
        purpose: Grovs::Hostnames::PURPOSE_PRIMARY
      )
      assert primary.ok, "primary create should succeed"
    end

    CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_m", status: "pending", ssl_status: "pending_validation" }) do
      migration = CustomDomainProvisioningService.create(
        project: projects(:one), hostname: "migration.acme.com",
        purpose: Grovs::Hostnames::PURPOSE_MIGRATION
      )
      assert migration.ok, "migration create should succeed alongside primary"
    end

    rows = CustomHostname.where(project: projects(:one)).order(:purpose)
    assert_equal 2, rows.count
    assert_equal %w[migration primary], rows.pluck(:purpose).sort
    assert_equal "primary.acme.com",   rows.find(&:primary?).hostname
    assert_equal "migration.acme.com", rows.find(&:migration?).hostname
  end

  test "same-purpose duplicate is rejected with :conflict" do
    CustomHostname.create!(project: projects(:one), domain: domains(:one),
                           hostname: "primary.first.com", status: "active",
                           source: "saas", purpose: Grovs::Hostnames::PURPOSE_PRIMARY)
    result = CustomDomainProvisioningService.create(
      project: projects(:one), hostname: "other.acme.com",
      purpose: Grovs::Hostnames::PURPOSE_PRIMARY
    )
    assert_not result.ok
    assert_equal :conflict, result.status
    assert_match(/already exists or is taken/, result.error)
  end

  test "reap_failed is purpose-scoped — a failed migration row is NOT reaped by a primary create" do
    CustomHostname.create!(project: projects(:one), domain: domains(:one),
                           hostname: "failed-migration.acme.com",
                           cf_custom_hostname_id: "cf_failed_mig",
                           status: "failed", source: "saas",
                           purpose: Grovs::Hostnames::PURPOSE_MIGRATION)

    cf_delete_called = false
    delete_stub = lambda do |**|
      cf_delete_called = true
      true
    end

    CloudflareCustomHostnameService.stub(:delete, delete_stub) do
      CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_new_primary", status: "pending", ssl_status: "pending_validation" }) do
        result = CustomDomainProvisioningService.create(
          project: projects(:one), hostname: "new-primary.acme.com",
          purpose: Grovs::Hostnames::PURPOSE_PRIMARY
        )
        assert result.ok
      end
    end

    assert CustomHostname.exists?(hostname: "failed-migration.acme.com"),
           "a failed migration row must not be reaped by a primary create"
    assert_not cf_delete_called, "no CF delete should be issued for the other purpose's failed row"
  end

  test "reap_failed is purpose-scoped — a failed migration row IS reaped by a migration create" do
    CustomHostname.create!(project: projects(:one), domain: domains(:one),
                           hostname: "failed-migration.acme.com",
                           cf_custom_hostname_id: "cf_failed_mig",
                           status: "failed", source: "saas",
                           purpose: Grovs::Hostnames::PURPOSE_MIGRATION)

    CloudflareCustomHostnameService.stub(:delete, true) do
      CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_fresh_mig", status: "pending", ssl_status: "pending_validation" }) do
        result = CustomDomainProvisioningService.create(
          project: projects(:one), hostname: "fresh-migration.acme.com",
          purpose: Grovs::Hostnames::PURPOSE_MIGRATION
        )
        assert result.ok, "the failed same-purpose row should have been reaped, freeing the slot"
      end
    end

    assert_not CustomHostname.exists?(hostname: "failed-migration.acme.com"),
               "the failed migration row should be reaped when creating a new migration row"
    assert CustomHostname.exists?(hostname: "fresh-migration.acme.com")
  end

  test "destroy of primary clears active_custom_host while leaving the migration row intact" do
    primary = CustomHostname.create!(project: projects(:one), domain: domains(:one),
                                     hostname: "primary.acme.com", cf_custom_hostname_id: "cf_p",
                                     status: "active", source: "saas",
                                     purpose: Grovs::Hostnames::PURPOSE_PRIMARY)
    migration = CustomHostname.create!(project: projects(:one), domain: domains(:one),
                                       hostname: "old-branch.acme.com", cf_custom_hostname_id: "cf_m",
                                       status: "active", source: "saas",
                                       purpose: Grovs::Hostnames::PURPOSE_MIGRATION)
    domains(:one).update!(active_custom_host: primary.hostname)

    CloudflareCustomHostnameService.stub(:delete, true) do
      assert CustomDomainProvisioningService.destroy(primary)
    end

    assert_not CustomHostname.exists?(primary.id), "primary row destroyed"
    assert CustomHostname.exists?(migration.id), "migration row must survive primary teardown"
    assert_nil domains(:one).reload.active_custom_host, "branding cleared when primary is destroyed"
  end

  test "destroy of migration leaves active_custom_host and the primary row untouched" do
    primary = CustomHostname.create!(project: projects(:one), domain: domains(:one),
                                     hostname: "primary.acme.com", cf_custom_hostname_id: "cf_p",
                                     status: "active", source: "saas",
                                     purpose: Grovs::Hostnames::PURPOSE_PRIMARY)
    migration = CustomHostname.create!(project: projects(:one), domain: domains(:one),
                                       hostname: "old-branch.acme.com", cf_custom_hostname_id: "cf_m",
                                       status: "active", source: "saas",
                                       purpose: Grovs::Hostnames::PURPOSE_MIGRATION)
    domains(:one).update!(active_custom_host: primary.hostname)

    CloudflareCustomHostnameService.stub(:delete, true) do
      assert CustomDomainProvisioningService.destroy(migration)
    end

    assert_not CustomHostname.exists?(migration.id), "migration row destroyed"
    assert CustomHostname.exists?(primary.id), "primary row must survive migration teardown"
    assert_equal primary.hostname, domains(:one).reload.active_custom_host,
                 "primary branding must remain when migration is torn down"
  end

  test "create requests TXT validation from Cloudflare (zero-downtime SSL issuance)" do
    captured_method = nil
    create_stub = lambda do |**kwargs|
      captured_method = kwargs[:ssl_method]
      { success: true, cf_id: "cf_txt", status: "pending", ssl_status: "pending_validation",
        ssl_method: "txt",
        txt_records: [{ "name" => "_acme-challenge.links.acmeco.com", "value" => "v" }] }
    end
    CloudflareCustomHostnameService.stub(:create, create_stub) do
      CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.acmeco.com")
    end
    assert_equal "txt", captured_method,
                 "service must request TXT-method SSL by default so customers can validate before CNAME flip"
  end

  test "create persists the TXT validation records returned by Cloudflare" do
    cf_response = { success: true, cf_id: "cf_txt", status: "pending", ssl_status: "pending_validation",
                    ssl_method: "txt",
                    txt_records: [
                      { "name" => "_acme-challenge.links.txtco.com", "value" => "abc-challenge-token" }
                    ] }
    CloudflareCustomHostnameService.stub(:create, cf_response) do
      result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.txtco.com")
      assert result.ok
      ch = result.custom_hostname
      assert_equal "txt", ch.ssl_method
      assert_equal [{ "name" => "_acme-challenge.links.txtco.com", "value" => "abc-challenge-token" }],
                   ch.ssl_validation_txt_records
    end
  end

  test "create tolerates a CF response with no TXT records (e.g. http fallback / lookup adoption)" do
    cf_response = { success: true, cf_id: "cf_no_txt", status: "pending", ssl_status: "pending_validation",
                    ssl_method: nil, txt_records: [] }
    CloudflareCustomHostnameService.stub(:create, cf_response) do
      result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.notxt.com")
      assert result.ok
      ch = result.custom_hostname
      assert_nil ch.ssl_method
      assert_equal [], ch.ssl_validation_txt_records,
                   "no challenge from CF → empty array, never NULL"
    end
  end

  # Hostname Pre-Validation TXT — CF's second TXT challenge on zones with pre-validation
  # enabled. The dashboard must show BOTH the _acme-challenge SSL record AND the
  # _cf-custom-hostname pre-validation record; CF refuses to issue the cert until both
  # resolve. Persisting them at create time avoids the ~60s gap before the refresh
  # job's first tick (when the customer is most actively waiting for the records).
  test "create persists the ownership_verification TXT name and value" do
    cf_response = { success: true, cf_id: "cf_ov", status: "pending", ssl_status: "pending_validation",
                    ssl_method: "txt",
                    txt_records: [{ "name" => "_acme-challenge.links.ovco.com", "value" => "ssl-token" }],
                    ov_txt_name: "_cf-custom-hostname.links.ovco.com",
                    ov_txt_value: "ownership-uuid" }
    CloudflareCustomHostnameService.stub(:create, cf_response) do
      result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.ovco.com")
      assert result.ok
      ch = result.custom_hostname
      assert_equal "_cf-custom-hostname.links.ovco.com", ch.ownership_verification_txt_name
      assert_equal "ownership-uuid",                     ch.ownership_verification_txt_value
    end
  end

  # ── Multi-record SSL validation persistence (Option A array column) ─────────
  # ssl_validation_txt_records is the canonical store; CF can emit multiple TXT
  # challenges (multi-CA dual issuance) and the array must survive end-to-end.

  test "create persists ssl_validation_txt_records as an array with both entries on multi-CA issuance" do
    cf_response = { success: true, cf_id: "cf_multi", status: "pending", ssl_status: "pending_validation",
                    ssl_method: "txt",
                    txt_records: [
                      { "name" => "_acme-challenge.x", "value" => "CA1" },
                      { "name" => "_acme-challenge.x", "value" => "CA2" }
                    ] }
    CloudflareCustomHostnameService.stub(:create, cf_response) do
      result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.multi-ca.com")
      assert result.ok
      ch = result.custom_hostname
      assert_equal 2, ch.ssl_validation_txt_records.size
      assert_equal %w[CA1 CA2], ch.ssl_validation_txt_records.map { |r| r["value"] }
    end
  end

  test "create defaults ssl_validation_txt_records to [] when CF returns nil txt_records" do
    cf_response = { success: true, cf_id: "cf_no_records", status: "pending", ssl_status: "pending_validation",
                    ssl_method: nil, txt_records: nil }
    CloudflareCustomHostnameService.stub(:create, cf_response) do
      result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.no-records.com")
      assert result.ok
      assert_equal [], result.custom_hostname.ssl_validation_txt_records,
                   "missing txt_records (nil) must persist as empty array, not NULL"
    end
  end

  test "create tolerates a CF response with no ownership_verification (zone without pre-validation)" do
    cf_response = { success: true, cf_id: "cf_no_ov", status: "pending", ssl_status: "pending_validation",
                    ssl_method: "txt",
                    txt_records: [{ "name" => "_acme-challenge.links.noov.com", "value" => "ssl-token" }],
                    ov_txt_name: nil, ov_txt_value: nil }
    CloudflareCustomHostnameService.stub(:create, cf_response) do
      result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.noov.com")
      assert result.ok
      ch = result.custom_hostname
      assert_nil ch.ownership_verification_txt_name,
                 "no pre-validation on the zone → row must carry nil, not crash"
      assert_nil ch.ownership_verification_txt_value
    end
  end

  # Pins the surprising behavior: failed rows hard-delete even on CF-delete false,
  # because a same-hostname retry re-adopts any lingering CF hostname via create()'s lookup.
  test "reap_failed hard-deletes the failed row even when CF delete returns false" do
    CustomHostname.create!(project: projects(:one), domain: domains(:one),
                           hostname: "links.failed-cf-down.com",
                           cf_custom_hostname_id: "cf_failed",
                           status: "failed", source: "saas")

    CloudflareCustomHostnameService.stub(:delete, false) do
      CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_new", status: "pending", ssl_status: "pending_validation" }) do
        result = CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.new.com")
        assert result.ok, "reap must proceed past a failed CF delete so the new create can claim the slot"
      end
    end
    assert_not CustomHostname.exists?(hostname: "links.failed-cf-down.com"),
               "the failed row must be hard-deleted regardless of CF delete outcome"
  end

  test "reap_failed leaves nothing behind even when CF raises mid-reap (defense in depth)" do
    CustomHostname.create!(project: projects(:one), domain: domains(:one),
                           hostname: "links.cf-raises.com",
                           cf_custom_hostname_id: "cf_raises",
                           status: "failed", source: "saas")

    delete_stub = ->(*_) { false }

    CloudflareCustomHostnameService.stub(:delete, delete_stub) do
      CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_x", status: "pending", ssl_status: "pending_validation" }) do
        CustomDomainProvisioningService.create(project: projects(:one), hostname: "links.replacement.com")
      end
    end
    assert_not CustomHostname.exists?(hostname: "links.cf-raises.com"),
               "reap_failed must converge on row-gone regardless of CF return value"
  end

  test "destroy: re-running on an already-suspended row leaves it suspended and retries CF" do
    ch = CustomHostname.create!(project: projects(:one), domain: domains(:one),
                                hostname: "links.retry.com", cf_custom_hostname_id: "cf_retry",
                                status: "suspended", source: "saas")

    cf_calls = 0
    delete_stub = lambda do |**|
      cf_calls += 1
      false
    end
    CloudflareCustomHostnameService.stub(:delete, delete_stub) do
      result = CustomDomainProvisioningService.destroy(ch)
      assert_not result, "still-failed CF delete must report not-destroyed"
    end
    assert_equal 1, cf_calls, "retry must re-attempt the CF delete"
    assert CustomHostname.exists?(ch.id), "row must remain for the next retry"
    assert_equal "suspended", ch.reload.status, "status must NOT flap back to active"
  end

  test "as_enterprise admin path supports both primary and migration purposes" do
    StripeSubscription.where(instance_id: instances(:two).id).delete_all
    project = Project.find(projects(:two).id)
    assert_not project.instance.custom_domains_entitled?, "guard: admin path must work without entitlement"

    CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_ent_p", status: "pending", ssl_status: "pending_validation" }) do
      result = CustomDomainProvisioningService.create(
        project: project, hostname: "ent-primary.acme.com",
        as_enterprise: true, purpose: Grovs::Hostnames::PURPOSE_PRIMARY
      )
      assert result.ok
      assert_equal "enterprise", result.custom_hostname.source
      assert result.custom_hostname.primary?
    end

    CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_ent_m", status: "pending", ssl_status: "pending_validation" }) do
      result = CustomDomainProvisioningService.create(
        project: project, hostname: "ent-migration.acme.com",
        as_enterprise: true, purpose: Grovs::Hostnames::PURPOSE_MIGRATION
      )
      assert result.ok
      assert_equal "enterprise", result.custom_hostname.source
      assert result.custom_hostname.migration?
    end
  end
end
