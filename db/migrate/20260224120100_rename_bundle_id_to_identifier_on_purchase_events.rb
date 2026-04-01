class RenameBundleIdToIdentifierOnPurchaseEvents < ActiveRecord::Migration[7.0]
  def change
    if column_exists?(:purchase_events, :bundle_id)
      rename_column :purchase_events, :bundle_id, :identifier
    end
  end
end
