class CreateSubscriptionStates < ActiveRecord::Migration[7.0]
  def change
    create_table :subscription_states do |t|
      t.bigint :project_id, null: false
      t.string :original_transaction_id, null: false
      t.bigint :device_id
      t.bigint :link_id
      t.string :product_id
      t.string :latest_transaction_id
      t.string :purchase_type

      t.timestamps

      t.index [:project_id, :original_transaction_id],
              unique: true,
              name: "idx_subscription_states_project_orig_txn"
    end

    add_foreign_key :subscription_states, :projects, on_delete: :cascade
  end
end
