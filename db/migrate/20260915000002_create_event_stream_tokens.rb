class CreateEventStreamTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :event_stream_tokens do |t|
      t.bigint :project_id, null: false
      t.bigint :created_by_user_id
      t.string :name, null: false
      t.string :token_digest, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :event_stream_tokens, :token_digest, unique: true
    add_index :event_stream_tokens, :project_id
  end
end
