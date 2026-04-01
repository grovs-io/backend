class RenameProductToProject < ActiveRecord::Migration[6.1]
  def change
    rename_column :stripe_subscriptions, :product_id, :project_id
  end
end
