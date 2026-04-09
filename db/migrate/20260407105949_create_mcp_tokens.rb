class CreateMcpTokens < ActiveRecord::Migration[7.1]
  def change
    create_table :mcp_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.string :token_digest, null: false
      t.string :name, null: false
      t.datetime :expires_at, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :mcp_tokens, :token_digest, unique: true
    add_index :mcp_tokens, :expires_at
  end
end
