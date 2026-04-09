class AddIndexToMcpTokensClientId < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :mcp_tokens, :client_id, algorithm: :concurrently
  end
end
