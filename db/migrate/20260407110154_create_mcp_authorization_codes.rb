class CreateMcpAuthorizationCodes < ActiveRecord::Migration[7.1]
  def change
    create_table :mcp_authorization_codes do |t|
      t.references :user, null: false, foreign_key: true
      t.string :code, null: false
      t.string :redirect_uri, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps
    end

    add_index :mcp_authorization_codes, :code, unique: true
    add_index :mcp_authorization_codes, :expires_at
  end
end
