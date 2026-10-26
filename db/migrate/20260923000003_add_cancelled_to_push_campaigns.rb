class AddCancelledToPushCampaigns < ActiveRecord::Migration[8.1]
  def change
    add_column :push_campaigns, :cancelled, :integer, null: false, default: 0
  end
end
