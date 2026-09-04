class AddLedgerReadIndexesToPurchaseEvents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEXES = {
    "idx_purchase_events_ledger_link" => [:project_id, :link_id, :date],
    "idx_purchase_events_ledger_visitor" => [:project_id, :visitor_id, :date]
  }.freeze

  def up
    INDEXES.each do |name, columns|
      drop_if_invalid(name)
      add_index :purchase_events, columns, where: "processed", name: name,
                                           algorithm: :concurrently, if_not_exists: true
    end
  end

  def down
    INDEXES.each_key do |name|
      remove_index :purchase_events, name: name, algorithm: :concurrently, if_exists: true
    end
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
