require "test_helper"

class CustomHostnameTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :custom_hostnames, :redirect_configs,
           :migration_sources, :migrated_links, :links

  test "valid fixture is valid" do
    assert custom_hostnames(:acme_active).valid?
  end

  test "a row with a cf id is cloudflare-provisioned" do
    ch = custom_hostnames(:acme_active)
    ch.update_columns(cf_custom_hostname_id: "cf-123")

    assert ch.cloudflare?
    assert_not ch.manual?
  end

  test "a row without a cf id is manual" do
    ch = custom_hostnames(:acme_active)
    ch.update_columns(cf_custom_hostname_id: nil, status: "pending")

    assert ch.manual?
    assert_not ch.cloudflare?
  end

  test "a provisioning row with no cf id is still cloudflare - a crashed create, not a manual row" do
    ch = custom_hostnames(:acme_active)
    ch.update_columns(cf_custom_hostname_id: nil, status: "provisioning")

    assert ch.cloudflare?
    assert_not ch.manual?
  end

  test "provider identity survives cloudflare credentials disappearing" do
    ch = custom_hostnames(:acme_active)
    ch.update_columns(cf_custom_hostname_id: "cf-123")

    enable_manual_custom_domains!
    assert Grovs.manual_custom_domains?, "guard: the deployment is now in manual mode"
    assert ch.cloudflare?, "an existing Cloudflare row must not be reinterpreted as manual"
  ensure
    disable_custom_domains!
  end

  test "provider identity survives cloudflare credentials being introduced later" do
    ch = custom_hostnames(:acme_active)
    ch.update_columns(cf_custom_hostname_id: nil, status: "pending")

    enable_custom_domains!
    assert_not Grovs.manual_custom_domains?, "guard: the deployment is now in Cloudflare mode"
    assert ch.manual?, "an existing manual row must not be reinterpreted as Cloudflare"
  ensure
    disable_custom_domains!
  end

  test "destroy cascades to MigrationSource on the same host + project" do
    ch = custom_hostnames(:acme_active)
    source = migration_sources(:acme_branch)
    assert_equal ch.hostname, source.old_host
    assert_equal ch.project_id, source.project_id

    assert_difference "MigrationSource.count", -1 do
      ch.destroy
    end
    assert_nil MigrationSource.find_by(id: source.id)
  end

  test "destroy of a migration CustomHostname cascades through MigrationSource to MigratedLinks" do
    ch     = custom_hostnames(:acme_active)
    source = migration_sources(:acme_branch)
    cached = MigratedLink.create!(
      migration_source: source, old_path: "promo",
      status: MigratedLink::STATUS_NOT_FOUND, cached_until: 1.hour.from_now
    )
    source_id = source.id
    fixture_link_ids = MigratedLink.where(migration_source_id: source_id).pluck(:id)
    assert_operator fixture_link_ids.size, :>=, 1,
      "fixtures should seed at least one MigratedLink under acme_branch"

    ch.destroy

    assert_nil MigrationSource.find_by(id: source_id),
      "MigrationSource pinned to the destroyed migration host must be removed"
    assert_nil MigratedLink.find_by(id: cached.id),
      "newly-cached MigratedLink must be cascaded via dependent: :delete_all"
    assert_empty MigratedLink.where(id: fixture_link_ids),
      "all MigratedLink rows under the source must be cascaded — none should remain"
  end

  test "destroy of a primary CustomHostname leaves a sibling migration MigrationSource intact" do
    primary = CustomHostname.create!(
      project: projects(:one), domain: domains(:one),
      hostname: "links.brand-new.com", status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_PRIMARY
    )
    sibling_source = migration_sources(:acme_branch)
    sibling_cache  = MigratedLink.create!(
      migration_source: sibling_source, old_path: "promo",
      status: MigratedLink::STATUS_NOT_FOUND, cached_until: 1.hour.from_now
    )

    primary.destroy

    assert MigrationSource.exists?(sibling_source.id),
      "primary CH destroy must not touch the project's migration MigrationSource"
    assert MigratedLink.exists?(sibling_cache.id),
      "primary CH destroy must not touch the project's MigratedLink cache rows"
  end

  test "destroy does NOT touch MigrationSources on other projects (defensive scope by project_id)" do
    other_project = projects(:two)
    other_domain  = other_project.domain || domains(:two)
    CustomHostname.create!(
      project: other_project, domain: other_domain,
      hostname: "links.otherco.com", status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_MIGRATION
    )
    other_source = MigrationSource.create!(
      project: other_project, old_host: "links.otherco.com",
      provider: "branch", credentials: { "branch_key" => "y" }
    )

    custom_hostnames(:acme_active).destroy
    assert MigrationSource.exists?(other_source.id), "other project's source must survive"
  end

  test "destroy with no MigrationSource for that host is a no-op (no exception)" do
    migration_sources(:acme_branch).destroy
    assert_nothing_raised { custom_hostnames(:acme_active).destroy }
  end

  test "hostname is required" do
    ch = CustomHostname.new(project: projects(:one), domain: domains(:one), hostname: nil)
    assert_not ch.valid?
    assert_includes ch.errors[:hostname], "can't be blank"
  end

  test "hostname is unique" do
    dup = CustomHostname.new(project: projects(:one), domain: domains(:one),
                             hostname: custom_hostnames(:acme_active).hostname)
    assert_not dup.valid?
    assert_includes dup.errors[:hostname], "has already been taken"
  end

  test "normalizes hostname (downcase, strip, trailing dot)" do
    ch = CustomHostname.new(project: projects(:one), domain: domains(:one), hostname: "  LINKS.Fresh.com.  ")
    ch.validate
    assert_equal "links.fresh.com", ch.hostname
  end

  test "rejects apex hostname" do
    ch = CustomHostname.new(project: projects(:one), domain: domains(:one), hostname: "fresh.com")
    assert_not ch.valid?
    assert_includes ch.errors[:hostname], "must be a subdomain"
  end

  test "rejects a subdomain of one of our MAIN domains" do
    ch = CustomHostname.new(project: projects(:one), domain: domains(:one), hostname: "links.sqd.link")
    assert_not ch.valid?
    assert_includes ch.errors[:hostname], "is reserved"
  end

  test "rejects a garbage hostname" do
    ch = CustomHostname.new(project: projects(:one), domain: domains(:one), hostname: "not a hostname")
    assert_not ch.valid?
  end

  test "resolvable? only when active" do
    ch = custom_hostnames(:acme_active)
    assert ch.resolvable?
    ch.status = "pending"
    assert_not ch.resolvable?
    ch.status = "suspended"
    assert_not ch.resolvable?
  end

  test "status rejects the legacy removed value (no soft-delete tombstone)" do
    ch = custom_hostnames(:acme_active)
    ch.status = "removed"
    assert_not ch.valid?
    assert ch.errors[:status].present?
  end

  test "has database foreign keys to projects and domains" do
    conn = ActiveRecord::Base.connection
    assert conn.foreign_key_exists?(:custom_hostnames, :projects)
    assert conn.foreign_key_exists?(:custom_hostnames, :domains)
  end

  test "enterprise? reflects source" do
    assert_not custom_hostnames(:acme_active).enterprise?
    assert CustomHostname.new(source: "enterprise").enterprise?
  end

  test "status and source must be in the allowed set" do
    ch = custom_hostnames(:acme_active)
    ch.status = "bogus"
    assert_not ch.valid?
    ch.status = "active"
    ch.source = "bogus"
    assert_not ch.valid?
  end

  test "cache_keys_to_clear includes the hostname key and no domain_id key" do
    ch = custom_hostnames(:acme_active)
    keys = ch.cache_keys_to_clear
    assert_includes keys, "custom_hostnames:find_by:hostname:#{ch.hostname}:no_includes"
    assert_not(keys.any? { |k| k.include?("find_by:domain_id") })
  end

  test "DB index rejects a second hostname for the same project" do
    CustomHostname.create!(project: projects(:two), domain: domains(:two),
                           hostname: "links.first.com", status: "active", source: "saas")

    dup = CustomHostname.new(project: projects(:two), domain: domains(:two),
                             hostname: "links.second.com", status: "provisioning", source: "saas")

    # save!(validate: false) bypasses the app layer; only the DB index remains.
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end

  test "DB index allows a new hostname once the project's prior one is hard-deleted" do
    first = CustomHostname.create!(project: projects(:two), domain: domains(:two),
                                   hostname: "links.first.com", status: "active", source: "saas")
    first.destroy!

    assert_nothing_raised do
      CustomHostname.create!(project: projects(:two), domain: domains(:two),
                             hostname: "links.second.com", status: "active", source: "saas")
    end
  end

  test "rejects a raw Unicode (IDN) hostname" do
    ch = CustomHostname.new(project: projects(:one), domain: domains(:one),
                            hostname: "münchen.example.com")
    assert_not ch.valid?
    assert_includes ch.errors[:hostname], "must use ASCII (punycode) encoding"
  end

  test "accepts the punycode form of an IDN hostname" do
    ch = CustomHostname.new(project: projects(:one), domain: domains(:one),
                            hostname: "xn--mnchen-3ya.example.com")
    assert ch.valid?, ch.errors.full_messages.to_sentence
  end

  test "primary and migration purposes coexist on the same project" do
    primary_ch = CustomHostname.create!(
      project: projects(:two), domain: domains(:two),
      hostname: "links.brand.com", status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_PRIMARY
    )
    migration_ch = CustomHostname.create!(
      project: projects(:two), domain: domains(:two),
      hostname: "old-branch.brand.com", status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_MIGRATION
    )

    assert primary_ch.persisted?
    assert migration_ch.persisted?
    assert_equal 2, CustomHostname.where(project: projects(:two)).count
  end

  test "DB index rejects two primary hostnames for the same project (same purpose duplicate)" do
    CustomHostname.create!(
      project: projects(:two), domain: domains(:two),
      hostname: "links.first.com", status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_PRIMARY
    )
    dup = CustomHostname.new(
      project: projects(:two), domain: domains(:two),
      hostname: "links.second.com", status: "provisioning", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_PRIMARY
    )
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end

  test "purpose must be in the allowed set" do
    ch = CustomHostname.new(project: projects(:one), domain: domains(:one),
                            hostname: "links.bogus.com", status: "active", source: "saas",
                            purpose: "bogus")
    assert_not ch.valid?
    assert ch.errors[:purpose].present?
  end

  test "primary? and migration? predicates are mutually exclusive" do
    primary_ch = CustomHostname.create!(
      project: projects(:two), domain: domains(:two),
      hostname: "links.brand.com", status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_PRIMARY
    )
    migration_ch = CustomHostname.create!(
      project: projects(:two), domain: domains(:two),
      hostname: "old-branch.brand.com", status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_MIGRATION
    )

    assert primary_ch.primary?
    assert_not primary_ch.migration?

    assert migration_ch.migration?
    assert_not migration_ch.primary?
  end

  test "primary and migration scopes partition rows by purpose" do
    CustomHostname.create!(
      project: projects(:two), domain: domains(:two),
      hostname: "links.brand.com", status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_PRIMARY
    )
    CustomHostname.create!(
      project: projects(:two), domain: domains(:two),
      hostname: "old-branch.brand.com", status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_MIGRATION
    )

    primary_hosts   = CustomHostname.primary.pluck(:hostname)
    migration_hosts = CustomHostname.migration.pluck(:hostname)

    assert_includes primary_hosts, "links.brand.com"
    assert_not_includes primary_hosts, "old-branch.brand.com"
    assert_not_includes primary_hosts, custom_hostnames(:acme_active).hostname

    assert_includes migration_hosts, "old-branch.brand.com"
    assert_includes migration_hosts, custom_hostnames(:acme_active).hostname
    assert_not_includes migration_hosts, "links.brand.com"

    total = CustomHostname.count
    assert_equal total, CustomHostname.primary.count + CustomHostname.migration.count
  end

  # Under Rails 8.1's raise_on_assign_to_attr_readonly default, assignment itself raises.
  test "purpose is immutable after create (attr_readonly raises on assign in Rails 8.1)" do
    ch = CustomHostname.create!(
      project: projects(:two), domain: domains(:two),
      hostname: "links.brand.com", status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_PRIMARY
    )

    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      ch.update(purpose: Grovs::Hostnames::PURPOSE_MIGRATION)
    end
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      ch.update!(purpose: Grovs::Hostnames::PURPOSE_MIGRATION)
    end

    assert_equal Grovs::Hostnames::PURPOSE_PRIMARY, ch.reload.purpose
  end
end
