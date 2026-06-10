class AddActivePartialIndexToLinks < ActiveRecord::Migration[8.1]
  disable_ddl_transaction! # CONCURRENTLY can't run inside a transaction

  # Partial index over ACTIVE links only: soft-deleted (active=false) rows accumulate
  # and bloated the domain_id scan behind every Links search. Matches created_at DESC order.
  # Already built in prod; if_not_exists makes this a no-op there, builds it elsewhere.
  def change
    add_index :links, [:domain_id, :created_at],
              order: { created_at: :desc },
              where: "active",
              algorithm: :concurrently,
              name: "index_links_on_domain_id_active",
              if_not_exists: true
  end
end
