class BackfillCustomHostnamePurposes < ActiveRecord::Migration[8.1]
  # Redis DEL must run AFTER COMMIT, else a concurrent READ COMMITTED reader
  # repopulates the cache with pre-migration data before our COMMIT lands.
  disable_ddl_transaction!

  CONFLICT_COUNT_SQL = <<~SQL.freeze
    SELECT COUNT(*)
    FROM migration_sources ms
    JOIN custom_hostnames ch
      ON ch.hostname = ms.old_host AND ch.project_id = ms.project_id
  SQL

  AFFECTED_ROWS_SQL = <<~SQL.freeze
    SELECT ch.id AS custom_hostname_id, ch.domain_id
    FROM migration_sources ms
    JOIN custom_hostnames ch
      ON ch.hostname = ms.old_host AND ch.project_id = ms.project_id
  SQL

  # Scoped by d.id = ch.domain_id so a stray duplicate denorm on another row can't be wiped.
  CLEAR_ACTIVE_CUSTOM_HOST_SQL = <<~SQL.freeze
    UPDATE domains d
    SET active_custom_host = NULL
    FROM custom_hostnames ch
    JOIN migration_sources ms
      ON ch.hostname = ms.old_host AND ch.project_id = ms.project_id
    WHERE d.id = ch.domain_id AND d.active_custom_host = ch.hostname
  SQL

  FLIP_PURPOSE_SQL = <<~SQL.freeze
    UPDATE custom_hostnames ch
    SET purpose = 'migration'
    FROM migration_sources ms
    WHERE ch.hostname = ms.old_host AND ch.project_id = ms.project_id
  SQL

  def up
    conflict_count = ActiveRecord::Base.connection.select_value(CONFLICT_COUNT_SQL).to_i

    if conflict_count.positive? && ENV["CUSTOM_HOSTNAME_PURPOSE_BACKFILL_AUDITED"] != "true"
      raise <<~MSG.squish
        Refusing to backfill #{conflict_count} CustomHostname row(s) without explicit
        audit acknowledgment. Run `bundle exec rake custom_hostnames:audit_purpose_backfill`
        to review affected projects, then re-run with
        CUSTOM_HOSTNAME_PURPOSE_BACKFILL_AUDITED=true bundle exec rails db:migrate.
      MSG
    end

    affected = ActiveRecord::Base.transaction do
      rows = ActiveRecord::Base.connection.exec_query(AFFECTED_ROWS_SQL).to_a
      ActiveRecord::Base.connection.execute(CLEAR_ACTIVE_CUSTOM_HOST_SQL)
      ActiveRecord::Base.connection.execute(FLIP_PURPOSE_SQL)
      rows
    end

    invalidate_model_cache!(
      custom_hostname_ids: affected.map { |r| r["custom_hostname_id"] },
      domain_ids: affected.map { |r| r["domain_id"] }.uniq
    )
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Reversing this migration is unsafe once any project has acquired a " \
          "new primary CustomHostname alongside its backfilled migration row — " \
          "flipping the migration row back to 'primary' would violate the " \
          "composite unique index index_custom_hostnames_on_project_id_and_purpose. " \
          "If you really need to roll back, first audit and delete one purpose " \
          "per project, then reverse the schema/index swap manually."
  end

  private

  # Raw SQL bypasses after_commit :clear_cache; without this the cache keeps the old
  # purpose until the 5-min TTL.
  def invalidate_model_cache!(custom_hostname_ids:, domain_ids:)
    return if custom_hostname_ids.empty? && domain_ids.empty?
    return unless defined?(::REDIS)

    CustomHostname.where(id: custom_hostname_ids).find_each { |ch| ch.send(:clear_cache) } if custom_hostname_ids.any?
    Domain.where(id: domain_ids).find_each { |d| d.send(:clear_cache) } if domain_ids.any?
  rescue StandardError => e
    Rails.logger.warn(
      message: "backfill_custom_hostname_purposes_cache_invalidation_failed",
      error: e.message,
      custom_hostname_count: custom_hostname_ids.size,
      domain_count: domain_ids.size
    )
  end
end
