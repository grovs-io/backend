class AddActionsLinkForeignKey < ActiveRecord::Migration[8.1]
  disable_ddl_transaction! # batched purge + NOT VALID add — neither needs a wrapping txn

  BATCH = 10_000

  # Purge orphans stranded by historical hard link deletes, then let the FK
  # cascade make new ones impossible (replaces OrphanedActionsCleanupJob).
  def up
    loop do
      deleted = execute(<<~SQL).cmd_tuples
        DELETE FROM actions
        WHERE id IN (
          SELECT id FROM actions
          WHERE NOT EXISTS (SELECT 1 FROM links WHERE links.id = actions.link_id)
          LIMIT #{BATCH}
        )
      SQL
      break if deleted < BATCH
    end

    return if foreign_key_exists?(:actions, :links)

    # validate: false = no table scan; validated in the next migration
    add_foreign_key :actions, :links, on_delete: :cascade, validate: false
  end

  def down
    remove_foreign_key :actions, :links if foreign_key_exists?(:actions, :links)
  end
end
