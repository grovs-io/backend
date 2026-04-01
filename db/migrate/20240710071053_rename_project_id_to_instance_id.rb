class RenameProjectIdToInstanceId < ActiveRecord::Migration[6.1]
  def change
    rename_column :stripe_subscriptions, :project_id, :instance_id
    rename_column :stripe_payment_intents, :project_id, :instance_id
    
  end
end
