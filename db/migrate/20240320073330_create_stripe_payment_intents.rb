class CreateStripePaymentIntents < ActiveRecord::Migration[6.1]
  def change
    create_table :stripe_payment_intents do |t|
      t.belongs_to :user, null: false
      t.string :intent_id
      t.string :product_type

      t.timestamps
    end
  end
end
