require "test_helper"

class CustomDomainLifecycleJobTest < ActiveSupport::TestCase
  fixtures :instances, :users, :projects, :domains, :stripe_payment_intents, :stripe_subscriptions

  setup do
    enable_custom_domains!
    REDIS.flushdb
    CustomHostname.delete_all
    EnterpriseSubscription.delete_all
  end
  teardown { disable_custom_domains! }

  # instance two has a canceled subscription -> NOT entitled.
  def unentitled_hostname(**attrs)
    CustomHostname.create!({ project: projects(:two), domain: domains(:two),
                             hostname: "links.lapsed.com", cf_custom_hostname_id: "cf_l",
                             status: "active", source: "saas" }.merge(attrs))
  end

  test "a manual hostname with no subscription is never put into billing grace" do
    enable_manual_custom_domains!
    ch = CustomDomainProvisioningService.create(project: projects(:two), hostname: "links.selfhosted.com").custom_hostname

    CustomDomainLifecycleJob.new.perform

    assert_nil ch.reload.grace_until
  end

  test "a manual active hostname survives the grace window with its branding intact" do
    enable_manual_custom_domains!
    ch = CustomDomainProvisioningService.create(project: projects(:two), hostname: "links.selfhosted2.com").custom_hostname
    ch.update!(status: "active")
    domains(:two).update!(active_custom_host: ch.hostname)

    CustomDomainLifecycleJob.new.perform
    travel(8.days) { CustomDomainLifecycleJob.new.perform }

    assert CustomHostname.exists?(id: ch.id), "a self-hosted row must never be torn down for non-payment"
    assert_equal "active", ch.reload.status
    assert_equal ch.hostname, domains(:two).reload.active_custom_host
  end

  test "saas hostname on an unentitled instance enters grace and keeps resolving" do
    ch = unentitled_hostname
    CustomDomainLifecycleJob.new.perform
    assert ch.reload.grace_until.present?
    assert_equal "active", ch.status
  end

  test "torn down after grace expires: branding reverted, CF deleted, row hard-deleted" do
    ch = unentitled_hostname(grace_until: 1.day.ago)
    domains(:two).update!(active_custom_host: "links.lapsed.com")
    CloudflareCustomHostnameService.stub(:delete, true) do
      CustomDomainLifecycleJob.new.perform
    end
    assert_not CustomHostname.exists?(ch.id), "hostname is hard-deleted so it can be re-claimed"
    assert_nil domains(:two).reload.active_custom_host
  end

  test "CF delete failure suspends the row (non-resolvable) and keeps it for retry" do
    ch = unentitled_hostname(grace_until: 1.day.ago)
    domains(:two).update!(active_custom_host: "links.lapsed.com")
    CloudflareCustomHostnameService.stub(:delete, false) do
      CustomDomainLifecycleJob.new.perform
    end
    ch.reload
    assert_equal "suspended", ch.status
    assert_not ch.resolvable?, "a domain pending teardown must stop resolving even if CF delete fails"
    assert_equal "cf_l", ch.cf_custom_hostname_id
    assert_nil domains(:two).reload.active_custom_host
  end

  test "a suspended hostname is retried and hard-deleted once Cloudflare delete succeeds" do
    ch = unentitled_hostname(status: "suspended", cf_custom_hostname_id: "cf_l")
    CloudflareCustomHostnameService.stub(:delete, true) do
      CustomDomainLifecycleJob.new.perform
    end
    assert_not CustomHostname.exists?(ch.id)
  end

  test "suspended enterprise hostname is retried and hard-deleted once Cloudflare delete succeeds" do
    ch = unentitled_hostname(status: "suspended", source: "enterprise", cf_custom_hostname_id: "cf_enterprise")
    CloudflareCustomHostnameService.stub(:delete, true) do
      CustomDomainLifecycleJob.new.perform
    end
    assert_not CustomHostname.exists?(ch.id)
  end

  test "enterprise hostname is never torn down even when unentitled" do
    ch = unentitled_hostname(source: "enterprise", grace_until: 1.day.ago)
    CustomDomainLifecycleJob.new.perform
    assert_equal "active", ch.reload.status
  end

  test "entitled instance clears grace, no teardown" do
    ch = CustomHostname.create!(project: projects(:one), domain: domains(:one),
                                hostname: "links.ok.com", cf_custom_hostname_id: "cf_ok",
                                status: "active", source: "saas", grace_until: 1.day.ago)
    CustomDomainLifecycleJob.new.perform
    assert_nil ch.reload.grace_until
    assert_equal "active", ch.status
  end

  test "no-op when the feature is disabled" do
    ch = unentitled_hostname
    disable_custom_domains!
    CustomDomainLifecycleJob.new.perform
    assert_nil ch.reload.grace_until
  end

  # ---------------------------------------------------------------------------
  # Fairness + budget — regressions here only show under load
  # ---------------------------------------------------------------------------

  # Builds a fresh Instance/Project/Domain triple so a custom hostname can be created
  # without colliding with the unique (project_id) index. EnterpriseSubscription is
  # cleared in setup; unless we add one the instance is not entitled.
  def fresh_unentitled_hostname(suffix:, status: "active", **attrs)
    instance = Instance.create!(api_key: "k-fair-#{suffix}-#{SecureRandom.hex(4)}",
                                uri_scheme: "scheme-fair-#{suffix}-#{SecureRandom.hex(4)}")
    project  = Project.create!(name: "p#{suffix}", identifier: "p-fair-#{suffix}-#{SecureRandom.hex(4)}",
                               instance: instance)
    domain   = Domain.create!(project: project, domain: "sqd.link", subdomain: "fair-#{suffix}-#{SecureRandom.hex(4)}")
    CustomHostname.create!({ project: project, domain: domain,
                             hostname: "links.fair-#{suffix}.example",
                             cf_custom_hostname_id: "cf-fair-#{suffix}",
                             status: status, source: "saas" }.merge(attrs))
  end

  # Reduce per-run shares so the test exercises the bucket split without creating 50 rows.
  def with_shares(suspended:, active:)
    job = CustomDomainLifecycleJob
    %i[SUSPENDED_SHARE ACTIVE_SHARE MAX_ROWS_PER_RUN].each { |c| job.send(:remove_const, c) }
    job.const_set(:SUSPENDED_SHARE, suspended)
    job.const_set(:ACTIVE_SHARE, active)
    job.const_set(:MAX_ROWS_PER_RUN, suspended + active)
    yield
  ensure
    %i[SUSPENDED_SHARE ACTIVE_SHARE MAX_ROWS_PER_RUN].each { |c| job.send(:remove_const, c) }
    job.const_set(:SUSPENDED_SHARE, 25)
    job.const_set(:ACTIVE_SHARE, 25)
    job.const_set(:MAX_ROWS_PER_RUN, 50)
  end

  test "fairness: a glut of active rows cannot starve suspended rows" do
    suspended = Array.new(3) { |i| fresh_unentitled_hostname(suffix: "s#{i}", status: "suspended") }
    active    = Array.new(3) { |i| fresh_unentitled_hostname(suffix: "a#{i}", status: "active") }

    with_shares(suspended: 2, active: 2) do
      CloudflareCustomHostnameService.stub(:delete, true) do
        CustomDomainLifecycleJob.new.perform
      end
    end

    # SUSPENDED_SHARE=2: two suspended rows hard-deleted, one remains.
    destroyed_suspended = suspended.count { |ch| !CustomHostname.exists?(ch.id) }
    remaining_suspended = suspended.count { |ch| CustomHostname.exists?(ch.id) }
    assert_equal 2, destroyed_suspended,
      "suspended bucket must process its full share regardless of how many active rows exist"
    assert_equal 1, remaining_suspended

    # ACTIVE_SHARE=2: two active rows enter grace, one untouched.
    graced_active = active.count { |ch| ch.reload.grace_until.present? }
    assert_equal 2, graced_active,
      "active bucket must also receive its independent share"
  end

  test "budget exhaustion breaks the per-row loop before all candidates are processed" do
    rows = Array.new(3) { |i| fresh_unentitled_hostname(suffix: "b#{i}", status: "suspended") }

    cf_calls = 0
    # Stub budget_exhausted? to fire after the first row so we can observe the early break.
    CustomDomainLifecycleJob.class_eval do
      alias_method :__orig_budget_exhausted?, :budget_exhausted?
      define_method(:budget_exhausted?) do
        @__bx_called ||= 0
        @__bx_called += 1
        @__bx_called > 1
      end
    end

    begin
      CloudflareCustomHostnameService.stub(:delete, lambda { |*| 
        cf_calls += 1
        true
      }) do
        CustomDomainLifecycleJob.new.perform
      end
    ensure
      CustomDomainLifecycleJob.class_eval do
        alias_method :budget_exhausted?, :__orig_budget_exhausted?
        remove_method :__orig_budget_exhausted?
      end
    end

    assert_equal 1, cf_calls,
      "budget exhaustion must break the loop after the first row, leaving the rest for the next run"
    assert_equal 2, rows.count { |ch| CustomHostname.exists?(ch.id) }
  end
end
