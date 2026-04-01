class AddForeignKeysToInstanceRolesAndStripeSubscriptions < ActiveRecord::Migration[7.0]
  def change
    add_foreign_key :instance_roles, :instances
    add_foreign_key :instance_roles, :users
    add_foreign_key :stripe_subscriptions, :instances
    add_foreign_key :stripe_subscriptions, :stripe_payment_intents
  end
end
