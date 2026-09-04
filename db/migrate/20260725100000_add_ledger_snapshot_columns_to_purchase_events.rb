class AddLedgerSnapshotColumnsToPurchaseEvents < ActiveRecord::Migration[8.1]
  def up
    add_column :purchase_events, :visitor_id, :bigint
    add_column :purchase_events, :revenue_platform, :string

    # Ledger attribution is an immutable snapshot — link deletion must not erase it.
    remove_foreign_key :purchase_events, :links if foreign_key_exists?(:purchase_events, :links)
  end

  def down
    # Fails if links were deleted since (dangling snapshot ids) — expected: the FK
    # removal is the point of this migration.
    add_foreign_key :purchase_events, :links unless foreign_key_exists?(:purchase_events, :links)
    remove_column :purchase_events, :revenue_platform
    remove_column :purchase_events, :visitor_id
  end
end
