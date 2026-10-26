class IndexQueuedPushDeliveriesByAge < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # The tick's reconcile reads the oldest queued rows every minute; without it, a full scan.
  def change
    add_index :push_deliveries, :updated_at, where: "status = 'queued'", algorithm: :concurrently, name: "index_push_deliveries_queued_age"
  end
end
