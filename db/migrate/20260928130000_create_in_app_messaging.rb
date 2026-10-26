class CreateInAppMessaging < ActiveRecord::Migration[8.1]
  def change
    create_table :in_app_campaigns do |t|
      t.references :project, null: false, foreign_key: true, index: false
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :segment, foreign_key: { on_delete: :nullify }
      t.string :name, null: false
      t.string :status, null: false, default: "draft"
      t.integer :revision, null: false, default: 1
      t.string :template, null: false, default: "interstitial"
      t.jsonb :content, null: false, default: {}
      t.jsonb :triggers, null: false, default: []
      t.jsonb :conditions, null: false, default: []
      t.jsonb :caps, null: false, default: {}
      t.jsonb :schedule, null: false, default: {}
      t.integer :priority, null: false, default: 1
      t.integer :delay_seconds, null: false, default: 0
      t.string :audience_type, null: false, default: "all"
      t.jsonb :segment_definition
      t.string :segment_definition_hash
      t.string :segment_list_generation
      t.string :segment_key
      t.datetime :start_at
      t.datetime :end_at
      t.datetime :launched_at
      t.datetime :ended_at
      t.string :failure_reason
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :in_app_campaigns, %i[project_id status]
    add_index :in_app_campaigns, :start_at, where: "status = 'scheduled'"
    add_index :in_app_campaigns, :end_at, where: "status IN ('scheduled', 'live', 'paused') AND end_at IS NOT NULL"
    add_index :in_app_campaigns, :segment_key, where: "segment_key IS NOT NULL"

    create_table :in_app_views, primary_key: %i[in_app_campaign_id person_key] do |t|
      t.bigint :in_app_campaign_id, null: false
      t.string :person_key, null: false
      t.bigint :project_id, null: false
      t.integer :total, null: false, default: 0
      t.jsonb :recent, null: false, default: []
      t.datetime :updated_at, null: false
    end
    add_foreign_key :in_app_views, :in_app_campaigns, on_delete: :cascade
    add_index :in_app_views, %i[project_id person_key]

    create_table :in_app_settings do |t|
      t.references :project, null: false, foreign_key: true, index: { unique: true }
      t.boolean :enabled, null: false, default: true
      t.integer :session_cap, null: false, default: 10
      t.integer :day_cap, null: false, default: 10
      t.jsonb :test_visitor_ids, null: false, default: []
      t.timestamps
    end

    create_table :segment_memberships, primary_key: %i[visitor_id segment_key] do |t|
      t.bigint :visitor_id, null: false
      t.string :segment_key, null: false
      t.bigint :project_id, null: false
      t.datetime :confirmed_at, null: false
    end
    add_index :segment_memberships, %i[project_id segment_key]
  end
end
