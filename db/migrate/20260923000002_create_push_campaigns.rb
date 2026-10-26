class CreatePushCampaigns < ActiveRecord::Migration[8.1]
  def change
    create_table :push_campaigns do |t|
      t.references :project, null: false, foreign_key: true, index: false
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :link, foreign_key: { on_delete: :nullify }
      t.references :segment, foreign_key: { on_delete: :nullify }
      t.string :source, null: false, default: "dashboard"
      t.string :name, null: false
      t.string :title, null: false
      t.string :body, null: false
      t.string :image_url
      t.string :sound
      t.jsonb :data, null: false, default: {}
      t.string :audience_type, null: false
      t.jsonb :recipients, null: false, default: []
      t.jsonb :segment_definition
      t.string :segment_definition_hash
      t.string :segment_list_generation
      t.string :status, null: false, default: "draft"
      t.datetime :scheduled_at
      t.boolean :local_time, null: false, default: false
      t.string :timezone
      t.datetime :evaluated_at
      t.datetime :started_at
      t.datetime :finished_at
      t.string :failure_reason
      t.integer :busy_attempts, null: false, default: 0
      t.integer :targeted, null: false, default: 0
      t.integer :no_channel, null: false, default: 0
      t.integer :not_found, null: false, default: 0
      t.integer :queued, null: false, default: 0
      t.integer :delivered, null: false, default: 0
      t.integer :failed, null: false, default: 0
      t.integer :opened, null: false, default: 0
      t.jsonb :error_counts, null: false, default: {}
      t.boolean :audience_incomplete, null: false, default: false
      t.integer :audience_persons
      t.integer :audience_devices
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :push_campaigns, %i[project_id created_at], order: { created_at: :desc }
    add_index :push_campaigns, :scheduled_at, where: "status = 'scheduled'"
    add_index :push_campaigns, :id, where: "status = 'sending'", name: "index_push_campaigns_sending"

    create_table :push_deliveries do |t|
      t.references :push_campaign, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :visitor_id
      t.bigint :device_id
      t.string :platform
      t.string :recipient
      t.datetime :due_at
      t.string :status, null: false, default: "pending"
      t.bigint :rpush_notification_id
      t.string :error
      t.datetime :opened_at
      t.timestamps
    end
    add_index :push_deliveries, %i[push_campaign_id visitor_id], unique: true, where: "visitor_id IS NOT NULL",
              name: "index_push_deliveries_on_campaign_and_visitor"
    add_index :push_deliveries, %i[push_campaign_id status due_at id], name: "index_push_deliveries_claim"
    add_index :push_deliveries, :rpush_notification_id, where: "rpush_notification_id IS NOT NULL"
  end
end
