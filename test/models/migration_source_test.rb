require "test_helper"

class MigrationSourceTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :domains, :redirect_configs, :custom_hostnames,
           :migration_sources, :migrated_links, :links, :users, :instance_roles

  setup do
    @project = projects(:one)
    @source  = migration_sources(:acme_branch)
    # Set via model so the encrypts+serialize pipeline runs (fixtures store raw values).
    @source.update!(credentials: { "branch_key" => "key_live_fixture" })
    @source.reload
    assert_equal "links.acme.com", custom_hostnames(:acme_active).hostname
    assert_equal "active", custom_hostnames(:acme_active).status
  end

  test "valid with branch credentials and an active CustomHostname for the project" do
    @source.destroy
    src = MigrationSource.new(
      project: @project,
      old_host: "links.acme.com",
      provider: Grovs::Migrations::PROVIDER_BRANCH,
      credentials: { "branch_key" => "key_live_xxx" }
    )
    assert src.valid?, "expected valid: #{src.errors.full_messages.join('; ')}"
    assert src.save
  end

  test "rejects provider adjust in MVP (only branch + appsflyer)" do
    src = MigrationSource.new(
      project: @project, old_host: "links.acme.com",
      provider: "adjust", credentials: { "api_token" => "x", "app_token" => "y" }
    )
    assert_not src.valid?
    assert_includes src.errors[:provider].first, "is not included"
  end

  test "rejects provider singular in MVP" do
    src = MigrationSource.new(
      project: @project, old_host: "links.acme.com",
      provider: "singular", credentials: { "api_key" => "x" }
    )
    assert_not src.valid?
    assert_includes src.errors[:provider].first, "is not included"
  end

  test "credentials_shape_for_provider: Branch missing branch_key fails" do
    src = MigrationSource.new(
      project: @project, old_host: "links.acme.com",
      provider: Grovs::Migrations::PROVIDER_BRANCH, credentials: {}
    )
    assert_not src.valid?
    assert_includes src.errors[:credentials].first, "missing keys: branch_key"
  end

  test "credentials_shape_for_provider: AppsFlyer missing onelink_id fails" do
    src = MigrationSource.new(
      project: @project, old_host: "links.acme.com",
      provider: Grovs::Migrations::PROVIDER_APPSFLYER, credentials: { "api_token" => "x" }
    )
    assert_not src.valid?
    assert_includes src.errors[:credentials].first, "missing keys: onelink_id"
  end

  test "rejects host with scheme" do
    src = MigrationSource.new(
      project: @project, old_host: "https://links.acme.com",
      provider: Grovs::Migrations::PROVIDER_BRANCH, credentials: { "branch_key" => "x" }
    )
    assert_not src.valid?
    assert src.errors[:old_host].any?
  end

  test "rejects host with path" do
    src = MigrationSource.new(
      project: @project, old_host: "links.acme.com/abc",
      provider: Grovs::Migrations::PROVIDER_BRANCH, credentials: { "branch_key" => "x" }
    )
    assert_not src.valid?
    assert src.errors[:old_host].any?
  end

  test "custom_hostname_exists_for_project rejects when no CustomHostname exists" do
    other = projects(:two)
    src = MigrationSource.new(
      project: other, old_host: "no.such.host.example.com",
      provider: Grovs::Migrations::PROVIDER_BRANCH, credentials: { "branch_key" => "x" }
    )
    assert_not src.valid?
    assert_match(/must first be added as a migration-purpose custom domain/, src.errors[:old_host].join)
  end

  # Runtime safety still holds because MigrationResolver.custom_hostname_still_active? gates
  # inbound clicks; this relaxation lets POST /migrations persist both records atomically.
  test "custom_hostname_exists_for_project ACCEPTS a pending migration-purpose CH (validator relaxation)" do
    ch = custom_hostnames(:acme_active)
    ch.update!(status: "pending")

    @source.destroy
    src = MigrationSource.new(
      project: @project, old_host: "links.acme.com",
      provider: Grovs::Migrations::PROVIDER_BRANCH, credentials: { "branch_key" => "x" }
    )
    assert src.valid?, "expected valid (pending migration CH should pass): #{src.errors.full_messages.join('; ')}"
  ensure
    ch&.update!(status: "active")
  end

  test "custom_hostname_exists_for_project rejects a primary-purpose CustomHostname" do
    @source.destroy
    primary_ch = CustomHostname.create!(
      project: @project, domain: @project.domain,
      hostname: "primary.acme.example",
      status: "active", ssl_status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_PRIMARY
    )
    primary_ch.send(:clear_cache)

    src = MigrationSource.new(
      project: @project, old_host: "primary.acme.example",
      provider: Grovs::Migrations::PROVIDER_BRANCH, credentials: { "branch_key" => "x" }
    )
    assert_not src.valid?
    assert_match(/is the project's primary custom domain/, src.errors[:old_host].join)
  end

  test "custom_hostname_exists_for_project rejects a suspended migration-purpose CustomHostname (mid-teardown)" do
    @source.destroy
    ch = custom_hostnames(:acme_active)
    ch.update!(status: "suspended")
    src = MigrationSource.new(
      project: @project, old_host: "links.acme.com",
      provider: Grovs::Migrations::PROVIDER_BRANCH, credentials: { "branch_key" => "x" }
    )
    assert_not src.valid?
    assert_match(/being removed/, src.errors[:old_host].join)
  ensure
    ch&.update!(status: "active")
  end

  test "custom_hostname_exists_for_project accepts an active migration-purpose CustomHostname" do
    @source.destroy
    src = MigrationSource.new(
      project: @project, old_host: "links.acme.com",
      provider: Grovs::Migrations::PROVIDER_BRANCH, credentials: { "branch_key" => "x" }
    )
    assert src.valid?, "expected valid: #{src.errors.full_messages.join('; ')}"
    assert src.save
  end

  test "custom_hostname_exists_for_project rejects when no matching CustomHostname row exists for the project" do
    other = projects(:two)
    src = MigrationSource.new(
      project: other, old_host: "no.such.host.example.com",
      provider: Grovs::Migrations::PROVIDER_BRANCH, credentials: { "branch_key" => "x" }
    )
    assert_not src.valid?
    assert_match(/must first be added as a migration-purpose custom domain/, src.errors[:old_host].join)
  end

  # Pins running the validator on update (not new_record? only) — a refactor that scopes
  # it to creates would silently re-open the admin-PATCH vs lifecycle-destroy race.
  test "custom_hostname_exists_for_project rejects an UPDATE when the existing CH transitions to suspended" do
    @source.reload
    assert @source.valid?, "baseline: source must start valid against the active CH"

    custom_hostnames(:acme_active).update!(status: "suspended")

    assert_not @source.valid?,
           "validator must reject updates while CH is mid-teardown — closes the race " \
           "between admin's PATCH and the lifecycle job's destroy"
    assert_match(/being removed/, @source.errors[:old_host].join)
  ensure
    custom_hostnames(:acme_active).update!(status: "active")
  end

  test "custom_hostname_exists_for_project short-circuits when old_host is blank (no early CH lookup)" do
    @source.destroy
    src = MigrationSource.new(
      project: @project, old_host: "",
      provider: Grovs::Migrations::PROVIDER_BRANCH, credentials: { "branch_key" => "x" }
    )
    CustomHostname.stub(:redis_find_by, ->(*_) { flunk "validator must short-circuit on blank old_host" }) do
      src.valid?
    end
    assert_match(/can't be blank/, src.errors[:old_host].join)
  end

  test "before_validation downcases and strips host" do
    @source.destroy
    src = MigrationSource.new(
      project: @project, old_host: "  Links.Acme.COM  ",
      provider: Grovs::Migrations::PROVIDER_BRANCH, credentials: { "branch_key" => "x" }
    )
    src.valid?
    assert_equal "links.acme.com", src.old_host
  end

  test "before_validation strips trailing dot" do
    @source.destroy
    src = MigrationSource.new(
      project: @project, old_host: "links.acme.com.",
      provider: Grovs::Migrations::PROVIDER_BRANCH, credentials: { "branch_key" => "x" }
    )
    src.valid?
    assert_equal "links.acme.com", src.old_host
  end

  test "before_validation strips port" do
    @source.destroy
    src = MigrationSource.new(
      project: @project, old_host: "links.acme.com:443",
      provider: Grovs::Migrations::PROVIDER_BRANCH, credentials: { "branch_key" => "x" }
    )
    src.valid?
    assert_equal "links.acme.com", src.old_host
  end

  test "credentials column is encrypted at rest" do
    @source.update!(credentials: { "branch_key" => "key_live_super_secret" })
    raw = ActiveRecord::Base.connection.execute(
      "SELECT credentials FROM migration_sources WHERE id = #{@source.id}"
    ).first["credentials"]
    assert_not_nil raw
    assert_not_includes raw.to_s, "key_live_super_secret"
    assert_equal "key_live_super_secret", @source.reload.credentials["branch_key"]
  end

  test "credentials full round-trip: write Hash, reload fresh from DB, deserialize to Hash with key access" do
    @source.update!(credentials: { "branch_key" => "key_round_trip", "extra" => "value" })
    reloaded = MigrationSource.find(@source.id)
    creds = reloaded.credentials
    assert_kind_of Hash, creds, "credentials must deserialize to Hash, got #{creds.class}"
    assert_equal "key_round_trip", creds["branch_key"]
    assert_equal "key_round_trip", creds.fetch("branch_key")
    @source.update!(provider: "appsflyer", credentials: { "onelink_id" => "abc", "api_token" => "tok" })
    af_reloaded = MigrationSource.find(@source.id)
    assert_kind_of Hash, af_reloaded.credentials
    assert_equal "abc", af_reloaded.credentials["onelink_id"]
    assert_equal "tok", af_reloaded.credentials["api_token"]
  end

  test "health: healthy when enabled and no failures" do
    assert_equal :healthy, @source.health
  end

  test "health: degraded when enabled but consecutive_failures > 0" do
    @source.update_columns(consecutive_failures: 5, first_failure_at: Time.current)
    assert_equal :degraded, @source.reload.health
  end

  test "health: disabled when enabled is false" do
    @source.update!(enabled: false)
    assert_equal :disabled, @source.health
  end

  test "record_failure! increments counter atomically" do
    @source.record_failure!(500)
    assert_equal 1, @source.reload.consecutive_failures
    assert_equal 500, @source.last_error_status
    assert_not_nil @source.first_failure_at
  end

  test "record_failure! preserves first_failure_at across multiple calls (COALESCE)" do
    @source.record_failure!(500)
    original = @source.reload.first_failure_at
    sleep 0.05
    @source.record_failure!(502)
    assert_equal 2, @source.reload.consecutive_failures
    assert_equal original.to_i, @source.first_failure_at.to_i
  end

  test "record_success! resets failure counters but PRESERVES degraded_email_sent_at within cooldown" do
    @source.update_columns(
      consecutive_failures: 10,
      first_failure_at: 1.hour.ago,
      last_error_status: 500,
      degraded_email_sent_at: 30.minutes.ago
    )
    @source.record_success!
    @source.reload
    assert_equal 0, @source.consecutive_failures
    assert_nil @source.first_failure_at
    assert_nil @source.last_error_status
    assert_not_nil @source.degraded_email_sent_at
  end

  test "record_success! no-ops when row is clean (no DB write)" do
    initial_updated = @source.updated_at
    sleep 0.05
    @source.record_success!
    assert_equal initial_updated.to_i, @source.reload.updated_at.to_i
  end

  test "record_success! does NOT clear degraded_email_sent_at within the cooldown window" do
    sent_at = 1.hour.ago
    @source.update_columns(consecutive_failures: 5, first_failure_at: 2.hours.ago, degraded_email_sent_at: sent_at)
    @source.record_success!
    @source.reload
    assert_equal 0, @source.consecutive_failures
    assert_nil @source.first_failure_at
    assert_not_nil @source.degraded_email_sent_at,
      "degraded_email_sent_at must persist within #{MigrationSource::DEGRADED_EMAIL_COOLDOWN} cooldown"
  end

  test "record_success! clears degraded_email_sent_at once the cooldown has passed" do
    @source.update_columns(consecutive_failures: 0, first_failure_at: nil,
                           degraded_email_sent_at: 25.hours.ago)
    @source.record_success!
    assert_nil @source.reload.degraded_email_sent_at
  end

  test "flapping source: 401 → 200 → 401 within cooldown sends degraded email exactly ONCE" do
    call_count = 0
    fake_message = Class.new { def deliver_later; end }.new
    MigrationMailer.stub(:degraded_warning, lambda { |*| 
      call_count += 1
      fake_message
    }) do
      @source.update_columns(consecutive_failures: 1, first_failure_at: 2.hours.ago)
      @source.send(:notify_degraded_if_threshold_crossed!)
      assert_equal 1, call_count
      assert_not_nil @source.reload.degraded_email_sent_at

      @source.record_success!
      assert_not_nil @source.reload.degraded_email_sent_at, "gate must persist during cooldown"

      @source.record_failure!(401)
      @source.update_columns(first_failure_at: 2.hours.ago)
      @source.send(:notify_degraded_if_threshold_crossed!)
      assert_equal 1, call_count, "must NOT re-fire degraded email during cooldown flap"
    end
  end

  test "record_success! does NOT short-circuit on stale in-memory state" do
    @source.update_columns(consecutive_failures: 50, first_failure_at: 1.hour.ago)
    stale = MigrationSource.find(@source.id)
    stale.assign_attributes(consecutive_failures: 0, first_failure_at: nil)
    stale.record_success!
    assert_equal 0, @source.reload.consecutive_failures
    assert_nil @source.first_failure_at
  end

  test "exhausted? at 500 attempts" do
    @source.update_columns(consecutive_failures: 500)
    assert @source.reload.exhausted?
  end

  test "exhausted? after 2-day failure window" do
    @source.update_columns(consecutive_failures: 1, first_failure_at: 3.days.ago)
    assert @source.reload.exhausted?
  end

  test "exhausted? false when fresh and counter low" do
    assert_not @source.exhausted?
  end

  test "credentials change resets counters via before_update" do
    @source.update_columns(consecutive_failures: 50, first_failure_at: 1.hour.ago, last_error_status: 401)
    @source.update!(credentials: { "branch_key" => "fresh_key" })
    @source.reload
    assert_equal 0, @source.consecutive_failures
    assert_nil @source.first_failure_at
    assert_nil @source.last_error_status
  end

  test "enabling a disabled source resets counters" do
    @source.update_columns(enabled: false, consecutive_failures: 500, first_failure_at: 3.days.ago)
    @source.update!(enabled: true)
    @source.reload
    assert_equal 0, @source.consecutive_failures
    assert_nil @source.first_failure_at
  end

  test "credentials change on AUTO-disabled source RE-ENABLES it" do
    @source.update_columns(enabled: false, auto_disabled_at: 1.hour.ago,
                           consecutive_failures: 500, first_failure_at: 3.days.ago)
    @source.update!(credentials: { "branch_key" => "fresh_key" })
    @source.reload
    assert @source.enabled, "credentials change should auto-re-enable an auto-disabled source"
    assert_nil @source.auto_disabled_at, "auto_disabled_at must be cleared on re-enable"
    assert_equal 0, @source.consecutive_failures
    assert_nil @source.first_failure_at
  end

  test "credentials change on ADMIN-disabled source does NOT re-enable it" do
    @source.update!(enabled: false)
    assert_nil @source.auto_disabled_at
    @source.update!(credentials: { "branch_key" => "rotated" })
    @source.reload
    assert_not @source.enabled, "admin's explicit disable must be preserved across credential rotation"
  end

  test "disabling a source does NOT reset counters (only the off→on flip does)" do
    @source.update_columns(consecutive_failures: 5, first_failure_at: 1.hour.ago)
    @source.update!(enabled: false)
    @source.reload
    assert_equal 5, @source.consecutive_failures
  end

  # The queue adapter is :sidekiq, so we stub the mailer rather than asserting on the test adapter.
  test "disable_with_notification! is concurrency-idempotent (only one mailer call)" do
    @source.update_columns(consecutive_failures: 500, first_failure_at: 1.hour.ago, enabled: true)
    call_count = 0
    fake_message = Class.new { def deliver_later; end }.new
    MigrationMailer.stub(:credentials_invalid, lambda { |*| 
      call_count += 1
      fake_message
    }) do
      @source.record_failure!(401)
      @source.reload.record_failure!(401)
    end
    assert_equal 1, call_count
  end

  test "notify_degraded_if_threshold_crossed! fires exactly once (sets degraded_email_sent_at)" do
    @source.update_columns(consecutive_failures: 1, first_failure_at: 2.hours.ago)
    call_count = 0
    fake_message = Class.new { def deliver_later; end }.new
    MigrationMailer.stub(:degraded_warning, lambda { |*| 
      call_count += 1
      fake_message
    }) do
      @source.send(:notify_degraded_if_threshold_crossed!)
      assert_equal 1, call_count
      assert_not_nil @source.reload.degraded_email_sent_at
      @source.send(:notify_degraded_if_threshold_crossed!)
      assert_equal 1, call_count
    end
  end

  test "notify_degraded_if_threshold_crossed! does nothing within the 1h grace window" do
    @source.update_columns(consecutive_failures: 1, first_failure_at: 30.minutes.ago)
    call_count = 0
    fake_message = Class.new { def deliver_later; end }.new
    MigrationMailer.stub(:degraded_warning, lambda { |*| 
      call_count += 1
      fake_message
    }) do
      @source.send(:notify_degraded_if_threshold_crossed!)
    end
    assert_equal 0, call_count
  end
end
