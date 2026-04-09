class AddPkceToMcpAuthorizationCodes < ActiveRecord::Migration[7.1]
  def change
    add_column :mcp_authorization_codes, :client_id, :string, null: false, default: ""
    add_column :mcp_authorization_codes, :code_challenge, :string
    add_column :mcp_authorization_codes, :code_challenge_method, :string
    add_column :mcp_authorization_codes, :state, :string
    add_column :mcp_authorization_codes, :scope, :string
  end
end
