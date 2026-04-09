class AddClientIdAndRefreshToMcpTokens < ActiveRecord::Migration[7.1]
  def change
    add_column :mcp_tokens, :client_id, :string
    add_column :mcp_tokens, :refresh_token_digest, :string
    add_column :mcp_tokens, :scope, :string

    add_index :mcp_tokens, :refresh_token_digest, unique: true, where: "refresh_token_digest IS NOT NULL"
  end
end
