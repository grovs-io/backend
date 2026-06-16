require "test_helper"
require Rails.root.join("db/migrate/20260601101123_backfill_custom_hostname_purposes")

class BackfillCustomHostnamePurposesMigrationTest < ActionDispatch::IntegrationTest
  fixtures :instances, :projects, :domains, :custom_hostnames, :migration_sources

  ENV_KEY = "CUSTOM_HOSTNAME_PURPOSE_BACKFILL_AUDITED".freeze

  teardown { ENV.delete(ENV_KEY) }

  CLEAR_ACTIVE_CUSTOM_HOST_SQL = BackfillCustomHostnamePurposes::CLEAR_ACTIVE_CUSTOM_HOST_SQL
  FLIP_PURPOSE_SQL              = BackfillCustomHostnamePurposes::FLIP_PURPOSE_SQL

  test "flips CustomHostname to migration AND clears domains.active_custom_host" do
    ActiveRecord::Base.transaction do
      project = projects(:one)
      domain  = domains(:one)
      ch      = custom_hostnames(:acme_active)

      # purpose is attr_readonly under Rails 8.1; raw SQL is the only way to simulate legacy data.
      ActiveRecord::Base.connection.exec_update(
        "UPDATE custom_hostnames SET purpose = $1 WHERE id = $2",
        "test_setup_demote",
        [Grovs::Hostnames::PURPOSE_PRIMARY, ch.id]
      )
      domain.update_columns(active_custom_host: ch.hostname)

      # save(validate: false) bypasses custom_hostname_exists_for_project, which would reject
      # the source because the CH is no longer purpose=migration. Never use in production.
      source = migration_sources(:acme_branch)
      source.save(validate: false)

      assert_equal ch.hostname, source.old_host, "fixture sanity: source pinned to CH"
      assert_equal project.id, source.project_id, "fixture sanity: same project"
      assert_equal "primary", ch.reload.purpose
      assert_equal ch.hostname, domain.reload.active_custom_host
      assert_equal ch.hostname, domain.display_host,
                   "pre-state sanity: display_host renders on the custom host"

      ActiveRecord::Base.connection.execute(CLEAR_ACTIVE_CUSTOM_HOST_SQL)
      ActiveRecord::Base.connection.execute(FLIP_PURPOSE_SQL)

      assert_equal "migration", ch.reload.purpose,
                   "CustomHostname must be flipped to purpose=migration"
      assert_nil domain.reload.active_custom_host,
                 "domains.active_custom_host must be cleared so display_host falls back"
      assert_equal domain.full_domain, domain.display_host,
                   "display_host must fall back to full_domain (sqd.link host)"

      raise ActiveRecord::Rollback
    end
  end

  test "no MigrationSource rows => UPDATEs are a no-op (idempotent)" do
    ActiveRecord::Base.transaction do
      MigrationSource.delete_all

      ch_before     = custom_hostnames(:acme_active).reload.attributes
      domain_before = domains(:one).reload.attributes

      ch_count_before = CustomHostname.count
      domain_count_before = Domain.count

      affected_d  = ActiveRecord::Base.connection.exec_update(CLEAR_ACTIVE_CUSTOM_HOST_SQL)
      affected_ch = ActiveRecord::Base.connection.exec_update(FLIP_PURPOSE_SQL)

      assert_equal 0, affected_d, "no MigrationSources => no domains updated"
      assert_equal 0, affected_ch, "no MigrationSources => no custom_hostnames updated"
      assert_equal ch_count_before, CustomHostname.count
      assert_equal domain_count_before, Domain.count
      assert_equal ch_before["purpose"], custom_hostnames(:acme_active).reload.purpose
      after_active_custom_host = domains(:one).reload.active_custom_host
      if domain_before["active_custom_host"].nil?
        assert_nil after_active_custom_host
      else
        assert_equal domain_before["active_custom_host"], after_active_custom_host
      end

      raise ActiveRecord::Rollback
    end
  end

  test "refuses to flip rows when conflicts exist and CUSTOM_HOSTNAME_PURPOSE_BACKFILL_AUDITED is unset" do
    ENV.delete(ENV_KEY)

    ActiveRecord::Base.transaction do
      assert_operator(
        ActiveRecord::Base.connection.select_value(BackfillCustomHostnamePurposes::CONFLICT_COUNT_SQL).to_i,
        :>=, 1, "fixture sanity: expected at least one MigrationSource/CustomHostname overlap"
      )

      err = assert_raises(RuntimeError) do
        ActiveRecord::Migration.suppress_messages { BackfillCustomHostnamePurposes.new.up }
      end
      assert_match(/CUSTOM_HOSTNAME_PURPOSE_BACKFILL_AUDITED=true/, err.message)
      assert_match(/audit_purpose_backfill/, err.message)

      raise ActiveRecord::Rollback
    end
  end

  test "runs as no-op when no rows would be affected, regardless of env var" do
    ENV.delete(ENV_KEY)

    ActiveRecord::Base.transaction do
      MigrationSource.delete_all
      ch_purpose_before = custom_hostnames(:acme_active).reload.purpose

      assert_nothing_raised do
        ActiveRecord::Migration.suppress_messages { BackfillCustomHostnamePurposes.new.up }
      end

      assert_equal ch_purpose_before, custom_hostnames(:acme_active).reload.purpose

      raise ActiveRecord::Rollback
    end
  end

  test "flips rows when conflicts exist AND CUSTOM_HOSTNAME_PURPOSE_BACKFILL_AUDITED=true" do
    ENV[ENV_KEY] = "true"

    ActiveRecord::Base.transaction do
      ch     = custom_hostnames(:acme_active)
      domain = domains(:one)
      ActiveRecord::Base.connection.exec_update(
        "UPDATE custom_hostnames SET purpose = $1 WHERE id = $2",
        "test_setup_demote",
        [Grovs::Hostnames::PURPOSE_PRIMARY, ch.id]
      )
      domain.update_columns(active_custom_host: ch.hostname)
      migration_sources(:acme_branch).save(validate: false)

      assert_nothing_raised do
        ActiveRecord::Migration.suppress_messages { BackfillCustomHostnamePurposes.new.up }
      end
      assert_equal "migration", ch.reload.purpose
      assert_nil domain.reload.active_custom_host

      raise ActiveRecord::Rollback
    end
  end

  test "scoped UPDATE leaves an unrelated domain row's active_custom_host alone" do
    ENV[ENV_KEY] = "true"

    ActiveRecord::Base.transaction do
      ch     = custom_hostnames(:acme_active)
      domain = domains(:one)
      ActiveRecord::Base.connection.exec_update(
        "UPDATE custom_hostnames SET purpose = $1 WHERE id = $2",
        "test_setup_demote",
        [Grovs::Hostnames::PURPOSE_PRIMARY, ch.id]
      )
      domain.update_columns(active_custom_host: ch.hostname)
      migration_sources(:acme_branch).save(validate: false)

      unrelated = domains(:two)
      unrelated.update_columns(active_custom_host: ch.hostname)

      ActiveRecord::Migration.suppress_messages { BackfillCustomHostnamePurposes.new.up }

      assert_equal "migration", ch.reload.purpose
      assert_nil domain.reload.active_custom_host
      assert_equal ch.hostname, unrelated.reload.active_custom_host,
                   "unrelated domain row must be left untouched by the scoped UPDATE"

      raise ActiveRecord::Rollback
    end
  end

  test "invalidates ModelCachingExtension caches for affected CustomHostname and Domain" do
    ENV[ENV_KEY] = "true"

    ActiveRecord::Base.transaction do
      ch     = custom_hostnames(:acme_active)
      domain = domains(:one)
      ActiveRecord::Base.connection.exec_update(
        "UPDATE custom_hostnames SET purpose = $1 WHERE id = $2",
        "test_setup_demote",
        [Grovs::Hostnames::PURPOSE_PRIMARY, ch.id]
      )
      domain.update_columns(active_custom_host: ch.hostname)
      migration_sources(:acme_branch).save(validate: false)

      CustomHostname.redis_find_by(:hostname, ch.hostname)
      Domain.redis_find_by(:id, domain.id)

      ch_cache_key     = "custom_hostnames:find_by:hostname:#{ch.hostname}:no_includes"
      domain_cache_key = "domains:find_by:id:#{domain.id}:no_includes"

      assert REDIS.exists(ch_cache_key) > 0
      assert REDIS.exists(domain_cache_key) > 0

      ActiveRecord::Migration.suppress_messages { BackfillCustomHostnamePurposes.new.up }

      assert_equal 0, REDIS.exists(ch_cache_key)
      assert_equal 0, REDIS.exists(domain_cache_key)

      raise ActiveRecord::Rollback
    end
  end
end
