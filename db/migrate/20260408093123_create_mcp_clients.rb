class CreateMcpClients < ActiveRecord::Migration[7.1]
  def change
    create_table :mcp_clients do |t|
      t.string :client_id, null: false
      t.string :client_name, null: false
      t.jsonb :redirect_uris, null: false, default: []
      t.string :grant_types, default: "authorization_code"
      t.string :response_types, default: "code"
      t.string :token_endpoint_auth_method, default: "none"
      t.string :application_type, default: "native"
      t.string :client_uri
      t.string :logo_uri
      t.timestamps
    end

    add_index :mcp_clients, :client_id, unique: true
  end
end
