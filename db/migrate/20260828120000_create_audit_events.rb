class CreateAuditEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_chain_heads do |t|
      t.bigint :instance_id, null: false
      t.bigint :sequence, null: false, default: 0
      t.string :head_hash
      t.timestamps
    end
    add_index :audit_chain_heads, :instance_id, unique: true

    # No FK to instances: rows must survive tenant deletion (they are the evidence it happened).
    create_table :audit_events do |t|
      t.bigint :instance_id, null: false
      t.bigint :sequence, null: false
      t.string :action, null: false
      t.jsonb :actor, null: false, default: {}
      t.jsonb :target, null: false, default: {}
      t.jsonb :changes_data, null: false, default: {}
      t.string :outcome, null: false, default: "success"
      t.string :ip
      t.string :user_agent
      t.string :request_id
      t.datetime :occurred_at, null: false, precision: 6
      t.string :prev_hash
      t.string :hash_value, null: false
      t.datetime :created_at, null: false
    end
    add_index :audit_events, %i[instance_id sequence], unique: true
    add_index :audit_events, %i[instance_id action]
    add_index :audit_events, %i[instance_id occurred_at]

    create_table :audit_export_tokens do |t|
      t.bigint :instance_id, null: false
      t.bigint :created_by_user_id
      t.string :name, null: false
      t.string :token_digest, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :audit_export_tokens, :token_digest, unique: true
    add_index :audit_export_tokens, :instance_id
  end
end
