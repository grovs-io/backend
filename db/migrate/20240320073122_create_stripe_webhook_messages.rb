class CreateStripeWebhookMessages < ActiveRecord::Migration[6.1]
  def change
    create_table :stripe_webhook_messages do |t|
      t.jsonb :data
      t.string :message_type
      t.timestamps
    end
  end
end
