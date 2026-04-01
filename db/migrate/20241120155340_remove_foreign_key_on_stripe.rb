class RemoveForeignKeyOnStripe < ActiveRecord::Migration[7.0]
  def change
    remove_foreign_key :stripe_payment_intents, :projects
  end
end
