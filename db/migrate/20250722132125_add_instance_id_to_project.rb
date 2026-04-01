class AddInstanceIdToProject < ActiveRecord::Migration[7.0]
  def change
     add_column :iap_webhook_messages, :instance_id, :integer
  end
end
