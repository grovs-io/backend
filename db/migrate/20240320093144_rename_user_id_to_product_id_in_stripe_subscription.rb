class RenameUserIdToProductIdInStripeSubscription < ActiveRecord::Migration[6.1]
  def change
    rename_column :stripe_subscriptions, :user_id, :product_id
  end
end
