class CreateMigratedLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :migrated_links do |t|
      t.references :migration_source, null: false, foreign_key: { on_delete: :cascade }
      # If a materialized Link is deleted by an admin, preserve the cache row but null the
      # pointer. MigrationResolver#serve treats the orphan as "serve project_defaults" — NOT
      # as a cache miss that re-resolves and re-creates the Link. Otherwise admin's deletion
      # would be silently undone on the next click.
      t.references :link, foreign_key: { on_delete: :nullify }
      t.string  :old_path, null: false
      t.string  :status,   null: false                                 # resolved | not_found | transient_error
      t.datetime :cached_until                                         # NULL for resolved (permanent); set for negative entries
      t.timestamps
    end

    # Resolver hot-path lookup; also enforces single materialization per (source, slug).
    add_index :migrated_links, [:migration_source_id, :old_path], unique: true
    # Supports the cleanup job's WHERE status IN (...) AND cached_until < ? scan.
    add_index :migrated_links, [:status, :cached_until]

    # DB-level enforcement of the status enum. upsert (used by FirstHitMigration) bypasses
    # model validations, so without this constraint a future bug that wrote a mistyped status
    # would produce rows the resolver's case statement silently nils on, falling through to
    # FirstHitMigration on every click forever for that slug.
    add_check_constraint :migrated_links,
      "status IN ('resolved','not_found','transient_error')",
      name: "migrated_links_status_check"
  end
end
