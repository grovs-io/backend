class AddActivePartialIndexToLinks < ActiveRecord::Migration[8.1]
  disable_ddl_transaction! # CONCURRENTLY can't run inside a transaction

  INDEX_NAME = "index_links_on_domain_id_active".freeze

  # Partial index over ACTIVE links only: soft-deleted (active=false) rows accumulate
  # and bloated the domain_id scan behind every Links search. Matches created_at DESC order.
  # Already built in prod; if_not_exists makes this a no-op there, builds it elsewhere.
  def up
    # A failed CREATE INDEX CONCURRENTLY leaves an INVALID index behind, which
    # if_not_exists would silently keep — drop it so this rerun rebuilds it.
    drop_index_if_invalid(INDEX_NAME, :links)

    add_index :links, [:domain_id, :created_at],
              order: { created_at: :desc },
              where: "active",
              algorithm: :concurrently,
              name: INDEX_NAME,
              if_not_exists: true
  end

  def down
    remove_index :links, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end

  private

  def drop_index_if_invalid(name, table)
    invalid = select_value(<<~SQL)
      SELECT 1 FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = '#{name}' AND NOT i.indisvalid
    SQL
    remove_index table, name: name, algorithm: :concurrently, if_exists: true if invalid
  end
end
