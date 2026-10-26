class AddWinnerTimerToPushCampaigns < ActiveRecord::Migration[8.1]
  def change
    change_table :push_campaigns, bulk: true do |t|
      t.integer :winner_after_minutes
      t.string :winner_by, limit: 16
      t.datetime :winner_due_at
      t.string :winner, limit: 1
    end
    add_index :push_campaigns, :winner_due_at, where: "winner_due_at IS NOT NULL AND status = 'sent'"
  end
end
