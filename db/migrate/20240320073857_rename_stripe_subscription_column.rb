class RenameStripeSubscriptionColumn < ActiveRecord::Migration[6.1]
  def change
    rename_column :stripe_subscriptions, :payment_intent_id, :stripe_payment_intent_id
  end
end
