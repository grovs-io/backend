class AddNotNullToMcpTokensName < ActiveRecord::Migration[8.1]
  def change
    change_column_null :mcp_tokens, :name, false
  end
end
