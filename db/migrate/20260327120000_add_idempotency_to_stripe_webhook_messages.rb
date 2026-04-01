class AddIdempotencyToStripeWebhookMessages < ActiveRecord::Migration[7.1]
  def change
    change_table :stripe_webhook_messages, bulk: true do |t|
      t.string :stripe_event_id
      t.boolean :processed, default: true, null: false
      t.index :stripe_event_id, unique: true, where: "stripe_event_id IS NOT NULL"
    end
  end
end
