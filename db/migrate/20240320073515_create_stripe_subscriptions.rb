class CreateStripeSubscriptions < ActiveRecord::Migration[6.1]
  def change
    create_table :stripe_subscriptions do |t|
      t.belongs_to :user, null: false
      t.belongs_to :payment_intent
      
      t.string :subscription_id
      t.string :product_type
      t.boolean :active
      t.string :status
      t.string :customer_id
      t.time :cancels_at
      t.timestamps
    end
  end
end
