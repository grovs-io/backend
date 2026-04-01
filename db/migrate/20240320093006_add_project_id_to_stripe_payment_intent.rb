class AddProjectIdToStripePaymentIntent < ActiveRecord::Migration[6.1]
  def change
    add_reference :stripe_payment_intents, :project, foreign_key: true
  end
end
