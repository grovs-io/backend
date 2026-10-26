class CreateEventDestinations < ActiveRecord::Migration[8.1]
  def change
    create_table :event_destinations do |t|
      t.bigint :project_id, null: false
      t.bigint :created_by_user_id
      t.string :name, null: false
      t.string :kind, null: false
      t.string :status, null: false, default: "enabled"
      t.text :paused_reason
      t.jsonb :settings, null: false, default: {}
      t.text :signing_secret
      t.text :credentials
      t.string :event_types, array: true, null: false, default: []
      t.integer :batch_size, null: false, default: 100
      t.integer :concurrency, null: false, default: 4
      t.boolean :include_ip, null: false, default: false
      t.datetime :events_cursor_at, precision: 3
      t.string :events_cursor_id, null: false, default: ""
      t.datetime :purchases_cursor_at, precision: 3
      t.string :purchases_cursor_id, null: false, default: ""
      t.datetime :failing_since
      t.datetime :backoff_until
      t.integer :consecutive_failures, null: false, default: 0
      t.text :last_error
      t.datetime :last_attempt_at
      t.datetime :last_delivered_at
      t.bigint :delivered_count, null: false, default: 0
      t.timestamps
    end
    add_index :event_destinations, :project_id
    add_index :event_destinations, %i[status backoff_until]
  end
end
