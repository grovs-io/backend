class FixMigrationSourcesDrift < ActiveRecord::Migration[8.1]
  # The dev DB drifted: an early version of 20260528150000 ran without
  # `auto_disabled_at` and without the two CHECK constraints, then the file was
  # edited to add them but never re-ran on existing DBs. Production may or may
  # not be affected; this migration is idempotent so applying it everywhere is
  # safe. Code paths that depend on the column/constraints:
  #   - migration_source.rb#auto_disabled? (and the credentials-PATCH branch)
  #   - migration_resolver.rb (project_defaults fallback for auto-disabled sources)
  #   - migrated_link_test.rb's DB-CHECK regression tests
  def change
    unless column_exists?(:migration_sources, :auto_disabled_at)
      add_column :migration_sources, :auto_disabled_at, :datetime
    end

    unless check_constraint_exists?(:migration_sources, name: "migration_sources_provider_check")
      add_check_constraint :migration_sources,
        "provider IN ('branch','appsflyer')",
        name: "migration_sources_provider_check"
    end

    unless check_constraint_exists?(:migrated_links, name: "migrated_links_status_check")
      add_check_constraint :migrated_links,
        "status IN ('resolved','not_found','transient_error')",
        name: "migrated_links_status_check"
    end
  end

  private

  def check_constraint_exists?(table, name:)
    ActiveRecord::Base.connection
      .check_constraints(table)
      .any? { |c| c.name == name }
  end
end
