class AddCampaignToLinks < ActiveRecord::Migration[7.0]
  def change
    add_reference :links, :campaign, null: true, foreign_key: true
  end
end
