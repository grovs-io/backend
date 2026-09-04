class AddLedgerProductIndexToPurchaseEvents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX = "idx_purchase_events_ledger_firsts".freeze

  # Serves the DISTINCT ON (device_id, product_id) first-purchase resolution in
  # RevenueLedgerQuery (first_time_purchases / product_totals) presorted.
  def up
    drop_if_invalid(INDEX)
    add_index :purchase_events, [:project_id, :device_id, :product_id, :date, :id],
              where: "processed AND event_type IN ('buy', 'refund_reversed') AND device_id IS NOT NULL",
              name: INDEX, algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :purchase_events, name: INDEX, algorithm: :concurrently, if_exists: true
  end

  private

  # An interrupted CREATE INDEX CONCURRENTLY leaves an INVALID index that
  # if_not_exists would silently keep — drop it so the retry rebuilds.
  def drop_if_invalid(name)
    invalid = select_value(
      "SELECT NOT i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid " \
      "WHERE c.relname = #{connection.quote(name)}"
    )
    remove_index :purchase_events, name: name, algorithm: :concurrently, if_exists: true if invalid
  end
end
