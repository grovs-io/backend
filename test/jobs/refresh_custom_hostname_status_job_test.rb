require "test_helper"

class RefreshCustomHostnameStatusJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains

  setup do
    enable_custom_domains!
    REDIS.flushdb
    CustomHostname.delete_all
    # Orphan-sweep tests assert (no source → reaped) vs (source → skipped) and
    # need a clean MigrationSource baseline.
    MigrationSource.delete_all
  end
  teardown { disable_custom_domains! }

  def pending_hostname
    CustomHostname.create!(project: projects(:one), domain: domains(:one),
                           hostname: "links.acme.com", cf_custom_hostname_id: "cf_1",
                           status: "pending", source: "saas")
  end

  test "activates a pending hostname when Cloudflare reports SSL active and sets branding" do
    ch = pending_hostname
    CloudflareCustomHostnameService.stub(:status, { success: true, status: "active", ssl_status: "active" }) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert_equal "active", ch.reload.status
    assert ch.activated_at.present?
    assert_equal "links.acme.com", domains(:one).reload.active_custom_host
  end

  test "stores verification errors while still pending, no branding" do
    ch = pending_hostname
    CloudflareCustomHostnameService.stub(:status, { success: true, status: "pending", ssl_status: "pending_validation", verification_errors: "no CNAME" }) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert_equal "pending", ch.reload.status
    assert_equal "no CNAME", ch.verification_errors
    assert_nil domains(:one).reload.active_custom_host
  end

  # ── ssl_validation_txt_records — the canonical multi-record TXT store ──────
  # The most important lifecycle property for the FE: this array can grow, shrink,
  # rotate, or empty out at any point after creation. The refresh job is where each
  # of those transitions actually lands in the DB.

  test "refresh updates the txt_records array to CF's current value (rotation)" do
    ch = pending_hostname
    ch.update!(ssl_validation_txt_records: [
      { "name" => "_acme-challenge.links.acme.com", "value" => "old-token" }
    ])
    rotated = { success: true, status: "pending", ssl_status: "pending_validation",
                ssl_method: "txt",
                txt_records: [{ "name" => "_acme-challenge.links.acme.com", "value" => "rotated-token" }],
                verification_errors: nil }
    CloudflareCustomHostnameService.stub(:status, rotated) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    ch.reload
    assert_equal "txt", ch.ssl_method
    assert_equal [{ "name" => "_acme-challenge.links.acme.com", "value" => "rotated-token" }],
                 ch.ssl_validation_txt_records,
                 "dashboard must show the current TXT, not a stale earlier one"
  end

  test "refresh grows ssl_validation_txt_records from 1 entry to 2 (CF adds a second CA mid-setup)" do
    ch = pending_hostname
    ch.update!(ssl_validation_txt_records: [{ "name" => "_acme-challenge.x", "value" => "CA1" }])
    multi = { success: true, status: "pending", ssl_status: "pending_validation", ssl_method: "txt",
              txt_records: [
                { "name" => "_acme-challenge.x", "value" => "CA1" },
                { "name" => "_acme-challenge.x", "value" => "CA2" }
              ],
              verification_errors: nil }
    CloudflareCustomHostnameService.stub(:status, multi) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert_equal 2, ch.reload.ssl_validation_txt_records.size,
                 "FE must learn about the second CA as soon as CF emits it"
  end

  test "refresh rotates the whole txt_records array on CA-authority switchover" do
    # When CF moves from one CA to another (Google → SSL.com), the value(s) change
    # completely. The customer's previously-added record is no longer asked for; a
    # new one is. The array must reflect what CF currently wants.
    ch = pending_hostname
    ch.update!(ssl_validation_txt_records: [{ "name" => "_acme-challenge.x", "value" => "OLD" }])
    rotated = { success: true, status: "pending", ssl_status: "pending_validation", ssl_method: "txt",
                txt_records: [{ "name" => "_acme-challenge.x", "value" => "NEW" }],
                verification_errors: nil }
    CloudflareCustomHostnameService.stub(:status, rotated) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert_equal ["NEW"], ch.reload.ssl_validation_txt_records.map { |r| r["value"] }
  end

  test "activation empties ssl_validation_txt_records to []" do
    ch = pending_hostname
    ch.update!(ssl_validation_txt_records: [{ "name" => "_acme-challenge.x", "value" => "CA1" }])
    activated = { success: true, status: "active", ssl_status: "active", ssl_method: "txt",
                  txt_records: [] }
    CloudflareCustomHostnameService.stub(:status, activated) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert_equal [], ch.reload.ssl_validation_txt_records,
                 "FE's 'show this list' guard is array.length > 0 — must collapse to [] post-activation"
  end

  # ── Hostname Pre-Validation TXT (`ownership_verification`) ─────────────────────
  # Same lifecycle as ssl_validation_txt_records: populated on the pending/rotation
  # paths so the dashboard can render it, persisted on failure (so the customer can
  # see which record CF couldn't verify), nulled on activation.

  test "refresh populates the ownership_verification TXT on a still-pending hostname" do
    ch = pending_hostname
    pre_val = { success: true, status: "pending", ssl_status: "pending_validation",
                ssl_method: "txt",
                txt_records: [{ "name" => "_acme-challenge.links.acme.com", "value" => "ssl-token" }],
                ov_txt_name: "_cf-custom-hostname.links.acme.com",
                ov_txt_value: "ownership-uuid",
                verification_errors: nil }
    CloudflareCustomHostnameService.stub(:status, pre_val) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    ch.reload
    assert_equal "_cf-custom-hostname.links.acme.com", ch.ownership_verification_txt_name
    assert_equal "ownership-uuid",                     ch.ownership_verification_txt_value
  end

  test "refresh rotates a stale ownership_verification TXT to CF's current value" do
    ch = pending_hostname
    ch.update!(ownership_verification_txt_name: "_cf-custom-hostname.links.acme.com",
               ownership_verification_txt_value: "old-uuid")
    rotated = { success: true, status: "pending", ssl_status: "pending_validation",
                ssl_method: "txt",
                txt_records: [{ "name" => "_acme-challenge.links.acme.com", "value" => "ssl-token" }],
                ov_txt_name: "_cf-custom-hostname.links.acme.com",
                ov_txt_value: "rotated-uuid",
                verification_errors: nil }
    CloudflareCustomHostnameService.stub(:status, rotated) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert_equal "rotated-uuid", ch.reload.ownership_verification_txt_value,
                 "dashboard must show CF's current ownership token, not a stale persisted one"
  end

  test "activation also nulls the ownership_verification TXT fields" do
    ch = pending_hostname
    ch.update!(ownership_verification_txt_name: "_cf-custom-hostname.links.acme.com",
               ownership_verification_txt_value: "to-be-cleared")
    activated = { success: true, status: "active", ssl_status: "active", ssl_method: "txt",
                  txt_records: [], ov_txt_name: nil, ov_txt_value: nil }
    CloudflareCustomHostnameService.stub(:status, activated) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    ch.reload
    assert_nil ch.ownership_verification_txt_name,
               "no challenge to show once the hostname is validated"
    assert_nil ch.ownership_verification_txt_value
  end

  test "failure transition persists the final ownership_verification TXT for dashboard explanation" do
    ch = pending_hostname
    ch.update_column(:created_at, 73.hours.ago)
    final = { success: true, status: "pending", ssl_status: "pending_deployment",
              ssl_method: "txt",
              txt_records: [{ "name" => "_acme-challenge.links.acme.com", "value" => "ssl-token" }],
              ov_txt_name: "_cf-custom-hostname.links.acme.com",
              ov_txt_value: "final-uuid",
              verification_errors: "ownership TXT not found" }
    CloudflareCustomHostnameService.stub(:status, final) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    ch.reload
    assert_equal "failed", ch.status
    assert_equal "_cf-custom-hostname.links.acme.com", ch.ownership_verification_txt_name,
                 "failure must record CF's final ownership TXT so the dashboard can explain why"
    assert_equal "final-uuid", ch.ownership_verification_txt_value
  end

  test "marks a hostname failed after the deadline when Cloudflare still reports it inactive" do
    ch = pending_hostname
    ch.update_column(:created_at, 73.hours.ago)
    CloudflareCustomHostnameService.stub(:status, { success: true, status: "pending", ssl_status: "pending_validation" }) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert_equal "failed", ch.reload.status
  end

  test "failure transition persists the final txt_records (rotated value) for dashboard display" do
    ch = pending_hostname
    ch.update!(ssl_method: "txt",
               ssl_validation_txt_records: [
                 { "name" => "_acme-challenge.links.acme.com", "value" => "old-token" }
               ])
    ch.update_column(:created_at, 73.hours.ago)

    final = { success: true, status: "pending", ssl_status: "pending_deployment",
              ssl_method: "txt",
              txt_records: [
                { "name" => "_acme-challenge.links.acme.com", "value" => "final-rotated-token" }
              ],
              verification_errors: "TXT record not found at authoritative DNS" }
    CloudflareCustomHostnameService.stub(:status, final) do
      RefreshCustomHostnameStatusJob.new.perform
    end

    ch.reload
    assert_equal "failed", ch.status
    assert_equal "pending_deployment", ch.ssl_status
    assert_equal "txt", ch.ssl_method
    assert_equal [{ "name" => "_acme-challenge.links.acme.com", "value" => "final-rotated-token" }],
                 ch.ssl_validation_txt_records,
                 "failure transition records CF's CURRENT array, not the previously persisted one"
    assert_match(/TXT record not found/, ch.verification_errors)
  end

  test "failure transition with empty txt_records from CF clears any prior records" do
    ch = pending_hostname
    ch.update!(ssl_method: "txt",
               ssl_validation_txt_records: [
                 { "name" => "_acme-challenge.links.acme.com", "value" => "stale-token" }
               ])
    ch.update_column(:created_at, 73.hours.ago)

    final = { success: true, status: "pending", ssl_status: "deactivated",
              ssl_method: nil, txt_records: [],
              verification_errors: "deadline exceeded" }
    CloudflareCustomHostnameService.stub(:status, final) do
      RefreshCustomHostnameStatusJob.new.perform
    end

    ch.reload
    assert_equal "failed", ch.status
    assert_nil ch.ssl_method, "stale ssl_method must be cleared on terminal failure"
    assert_equal [], ch.ssl_validation_txt_records,
                 "stale TXT records must be cleared on terminal failure"
  end

  test "activates a hostname validated right at the deadline instead of force-failing it" do
    ch = pending_hostname
    ch.update_column(:created_at, 73.hours.ago)
    CloudflareCustomHostnameService.stub(:status, { success: true, status: "active", ssl_status: "active" }) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert_equal "active", ch.reload.status, "a row that validated must not be failed by a time check that ran first"
    assert_equal "links.acme.com", domains(:one).reload.active_custom_host
  end

  test "skips a row checked within the backoff window" do
    pending_hostname.update!(last_checked_at: 10.seconds.ago)
    called = false
    CloudflareCustomHostnameService.stub(:status, ->(**) { called = true }) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert_not called
  end

  test "no-op when the feature is disabled" do
    ch = pending_hostname
    disable_custom_domains!
    called = false
    CloudflareCustomHostnameService.stub(:status, ->(**) { called = true }) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert_not called
    assert_equal "pending", ch.reload.status
  end

  test "activating a migration-purpose hostname does NOT write active_custom_host" do
    primary = CustomHostname.create!(project: projects(:one), domain: domains(:one),
                                     hostname: "links.acme.com", cf_custom_hostname_id: "cf_primary",
                                     status: "active", source: "saas",
                                     purpose: Grovs::Hostnames::PURPOSE_PRIMARY,
                                     activated_at: 1.day.ago)
    domains(:one).update!(active_custom_host: primary.hostname)

    # A migration row on the same project, pending Cloudflare validation.
    migration = CustomHostname.create!(project: projects(:one), domain: domains(:one),
                                       hostname: "mig.old-vendor.com", cf_custom_hostname_id: "cf_mig",
                                       status: "pending", source: "saas",
                                       purpose: Grovs::Hostnames::PURPOSE_MIGRATION)

    CloudflareCustomHostnameService.stub(:status, { success: true, status: "active", ssl_status: "active" }) do
      RefreshCustomHostnameStatusJob.new.perform
    end

    assert_equal "active", migration.reload.status
    assert migration.activated_at.present?

    assert_equal primary.hostname, domains(:one).reload.active_custom_host,
      "migration-purpose activation must not leak into active_custom_host"
  end

  def stuck_provisioning(age:, **attrs)
    ch = CustomHostname.create!({ project: projects(:one), domain: domains(:one),
                                  hostname: "links.stuck.com", status: "provisioning",
                                  source: "saas" }.merge(attrs))
    ch.update_column(:created_at, age.ago)
    ch
  end

  test "deletes a provisioning row stuck past the stale threshold" do
    ch = stuck_provisioning(age: 20.minutes)
    RefreshCustomHostnameStatusJob.new.perform
    assert_not CustomHostname.exists?(ch.id), "a crashed provisioning reservation must be cleaned up"
  end

  test "leaves a fresh provisioning row alone (its create may still be in flight)" do
    ch = stuck_provisioning(age: 2.minutes)
    RefreshCustomHostnameStatusJob.new.perform
    assert CustomHostname.exists?(ch.id), "must not delete a provisioning row whose create may still be running"
    assert_equal "provisioning", ch.reload.status
  end

  test "recovering a stuck provisioning row frees the project's slot for a retry" do
    stuck_provisioning(age: 20.minutes)
    RefreshCustomHostnameStatusJob.new.perform
    assert_nothing_raised do
      CustomHostname.create!(project: projects(:one), domain: domains(:one),
                             hostname: "links.retry.com", status: "provisioning", source: "saas")
    end
  end

  test "recovery deletes the row without making any Cloudflare call" do
    ch = stuck_provisioning(age: 20.minutes)
    cf_called = false
    CloudflareCustomHostnameService.stub(:lookup, { success: false }) do
      CloudflareCustomHostnameService.stub(:delete, ->(**) { cf_called = true }) do
        RefreshCustomHostnameStatusJob.new.perform
      end
    end
    assert_not cf_called, "a row that never reached Cloudflare needs no CF call to clean up"
    assert_not CustomHostname.exists?(ch.id)
  end

  test "recovery KEEPS the DB row when CF orphan is found but CF delete fails" do
    ch = stuck_provisioning(age: 20.minutes)
    CloudflareCustomHostnameService.stub(:lookup, { success: true, cf_id: "cf_orphan_42" }) do
      CloudflareCustomHostnameService.stub(:delete, false) do
        RefreshCustomHostnameStatusJob.new.perform
      end
    end
    assert CustomHostname.exists?(ch.id),
      "DB row must be retained while a Cloudflare orphan still exists"
    assert_equal "provisioning", ch.reload.status, "status must be unchanged for next-tick retry"
  end

  test "recovery destroys the DB row when CF orphan is found AND CF delete succeeds" do
    ch = stuck_provisioning(age: 20.minutes)
    deleted_cf_id = nil
    CloudflareCustomHostnameService.stub(:lookup, { success: true, cf_id: "cf_orphan_99" }) do
      CloudflareCustomHostnameService.stub(:delete, lambda { |cf_id:| 
        deleted_cf_id = cf_id
        true
      }) do
        RefreshCustomHostnameStatusJob.new.perform
      end
    end
    assert_equal "cf_orphan_99", deleted_cf_id, "orphan must be deleted at CF before freeing the DB slot"
    assert_not CustomHostname.exists?(ch.id)
  end

  test "recovery does not touch pending or active rows" do
    pending = pending_hostname
    pending.update_column(:created_at, 20.minutes.ago)
    active = CustomHostname.create!(project: projects(:two), domain: domains(:two),
                                    hostname: "links.live.com", cf_custom_hostname_id: "cf_a",
                                    status: "active", source: "saas")
    active.update_column(:created_at, 20.minutes.ago)

    CloudflareCustomHostnameService.stub(:status, { success: true, status: "pending", ssl_status: "pending_validation" }) do
      RefreshCustomHostnameStatusJob.new.perform
    end

    assert CustomHostname.exists?(pending.id), "pending rows are refreshed, not deleted"
    assert CustomHostname.exists?(active.id), "active rows are untouched by provisioning recovery"
  end

  test "no-op recovery when the feature is disabled" do
    ch = stuck_provisioning(age: 20.minutes)
    disable_custom_domains!
    RefreshCustomHostnameStatusJob.new.perform
    assert CustomHostname.exists?(ch.id), "disabled feature must not run recovery"
  end

  def failed_hostname(checked_at:, **attrs)
    ch = CustomHostname.create!({ project: projects(:one), domain: domains(:one),
                                  hostname: "links.failed.com", cf_custom_hostname_id: "cf_f",
                                  status: "failed", source: "saas" }.merge(attrs))
    ch.update_column(:last_checked_at, checked_at)
    ch
  end

  test "reaps a failed row past the retention window, freeing the project's slot" do
    failed_hostname(checked_at: 8.days.ago)
    CloudflareCustomHostnameService.stub(:delete, true) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert_not CustomHostname.exists?(hostname: "links.failed.com"), "stale failed rows are reaped"
    assert_nothing_raised do
      CustomHostname.create!(project: projects(:one), domain: domains(:one),
                             hostname: "links.retry.com", status: "provisioning", source: "saas")
    end
  end

  test "keeps a recently failed row within the retention window for dashboard visibility" do
    ch = failed_hostname(checked_at: 1.hour.ago)
    CloudflareCustomHostnameService.stub(:delete, ->(**) { flunk "must not reap a fresh failed row" }) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert CustomHostname.exists?(ch.id)
    assert_equal "failed", ch.reload.status
  end

  def suspended_orphan(updated_at: 10.minutes.ago, **attrs)
    ch = CustomHostname.create!({ project: projects(:one), domain: domains(:one),
                                  hostname: "orphan.acme.com", cf_custom_hostname_id: "cf_orphan",
                                  status: "suspended", source: "saas",
                                  purpose: Grovs::Hostnames::PURPOSE_MIGRATION }.merge(attrs))
    ch.update_column(:updated_at, updated_at)
    ch
  end

  test "reap_orphaned_suspended retries CF delete for an orphaned suspended row" do
    ch = suspended_orphan
    CloudflareCustomHostnameService.stub(:delete, true) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert_not CustomHostname.exists?(ch.id),
               "suspended orphan must be destroyed once CF delete succeeds"
  end

  test "reap_orphaned_suspended skips suspended CHs that have a paired MigrationSource" do
    ch = suspended_orphan
    # save(validate: false) bypasses the suspended-CH validator; we need the row to exist
    # so the sweep's existence check has something to skip.
    src = MigrationSource.new(project: projects(:one), provider: "branch",
                              old_host: ch.hostname, credentials: { branch_key: "k" })
    src.save!(validate: false)
    CloudflareCustomHostnameService.stub(:delete, ->(**) { flunk "must not retry teardown when a source still points at this CH" }) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert CustomHostname.exists?(ch.id), "suspended-with-source rows belong to the lifecycle job, not this sweeper"
  end

  test "reap_orphaned_suspended skips suspended CHs newer than the grace window" do
    ch = suspended_orphan(updated_at: 30.seconds.ago)
    CloudflareCustomHostnameService.stub(:delete, ->(**) { flunk "must not race a fresh suspension" }) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert CustomHostname.exists?(ch.id), "in-flight teardown must not be raced"
    assert_equal "suspended", ch.reload.status
  end

  test "reaping a failed row deletes its Cloudflare hostname" do
    failed_hostname(checked_at: 8.days.ago, cf_custom_hostname_id: "cf_reap")
    deleted = nil
    record_delete = lambda do |cf_id:|
      deleted = cf_id
      true
    end
    CloudflareCustomHostnameService.stub(:delete, record_delete) do
      RefreshCustomHostnameStatusJob.new.perform
    end
    assert_equal "cf_reap", deleted
    assert_not CustomHostname.exists?(hostname: "links.failed.com")
  end

  test "budget exhaustion breaks the pending-refresh loop after the first row" do
    pending = Array.new(3) do |i|
      instance = Instance.create!(api_key: "rk-#{i}-#{SecureRandom.hex(4)}",
                                  uri_scheme: "rs-#{i}-#{SecureRandom.hex(4)}")
      project  = Project.create!(name: "rp#{i}", identifier: "rp-#{i}-#{SecureRandom.hex(4)}", instance: instance)
      domain   = Domain.create!(project: project, domain: "sqd.link",
                                subdomain: "ref-#{i}-#{SecureRandom.hex(4)}")
      CustomHostname.create!(project: project, domain: domain,
                             hostname: "links.ref-#{i}.example", cf_custom_hostname_id: "cf-r-#{i}",
                             status: "pending", source: "saas")
    end

    status_calls = 0
    RefreshCustomHostnameStatusJob.class_eval do
      alias_method :__orig_budget_exhausted?, :budget_exhausted?
      define_method(:budget_exhausted?) do
        @__bx ||= 0
        @__bx += 1
        @__bx > 1
      end
    end

    begin
      CloudflareCustomHostnameService.stub(:status, lambda { |**|
        status_calls += 1
        { success: false, status: "pending", ssl_status: "pending_validation", verification_errors: nil }
      }) do
        RefreshCustomHostnameStatusJob.new.perform
      end
    ensure
      RefreshCustomHostnameStatusJob.class_eval do
        alias_method :budget_exhausted?, :__orig_budget_exhausted?
        remove_method :__orig_budget_exhausted?
      end
    end

    assert_equal 1, status_calls,
      "budget exhaustion must break pending refresh after one row, leaving the rest for next run"
    stamped = pending.count { |ch| ch.reload.last_checked_at.present? }
    assert_equal 1, stamped
  end
end
