class CreatePushCampaignCounters < ActiveRecord::Migration[8.1]
  def change
    create_table :push_campaign_counters, primary_key: %i[push_campaign_id shard] do |t| # rubocop:disable Rails/CreateTableWithTimestamps
      t.references :push_campaign, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.integer :shard, limit: 2, null: false
      t.bigint :queued, null: false, default: 0
      t.bigint :delivered, null: false, default: 0
      t.bigint :failed, null: false, default: 0
      t.jsonb :error_counts, null: false, default: {}
    end
    reversible do |dir|
      dir.up { execute "INSERT INTO push_campaign_counters (push_campaign_id, shard) SELECT id, s FROM push_campaigns, generate_series(0, 15) s" }
    end
  end
end
