class AddSubscriptionItemIdToSubscriptions < ActiveRecord::Migration[6.1]
  def change
    add_column :stripe_subscriptions, :subscription_item_id, :string
  end
end

