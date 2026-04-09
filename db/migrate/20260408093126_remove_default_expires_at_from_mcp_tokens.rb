class RemoveDefaultExpiresAtFromMcpTokens < ActiveRecord::Migration[8.1]
  def up
    change_column_default :mcp_tokens, :expires_at, from: -> { "(now() + 'P90D'::interval)" }, to: nil
  end

  def down
    change_column_default :mcp_tokens, :expires_at, from: nil, to: -> { "(now() + 'P90D'::interval)" }
  end
end
