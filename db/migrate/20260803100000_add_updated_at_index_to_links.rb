class AddUpdatedAtIndexToLinks < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX = "index_links_on_updated_at".freeze

  # ReconcileLinkDimensionsJob scans links by updated_at hourly; without this it is a seq scan.
  def up
    add_index :links, :updated_at, name: INDEX, algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :links, name: INDEX, algorithm: :concurrently, if_exists: true
  end
end
