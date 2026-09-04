class CreateSsoConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :sso_connections do |t|
      t.references :instance, null: false, foreign_key: true, index: { unique: true }
      t.string :issuer, null: false
      t.string :client_id, null: false
      t.string :client_secret, null: false
      t.datetime :client_secret_expires_at
      t.boolean :enforce, null: false, default: false
      t.boolean :jit_provision, null: false, default: true
      t.string :admin_claim_value
      t.string :scim_token_digest
      t.boolean :scim_enabled, null: false, default: false
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
    add_index :sso_connections, :scim_token_digest, unique: true, where: "scim_token_digest IS NOT NULL"

    create_table :sso_connection_domains do |t|
      t.references :sso_connection, null: false, foreign_key: { on_delete: :cascade }
      t.string :domain, null: false
      t.string :verification_token, null: false
      t.datetime :verified_at
      t.timestamps
    end
    add_index :sso_connection_domains, %i[sso_connection_id domain], unique: true
    add_index :sso_connection_domains, :domain, unique: true, where: "verified_at IS NOT NULL",
              name: "index_sso_connection_domains_one_verified_owner"

    add_column :users, :scim_external_id, :string
    add_column :users, :scim_user_name, :string
    add_index :users, %i[provider scim_external_id], unique: true, where: "scim_external_id IS NOT NULL"
    add_index :users, %i[provider scim_user_name], unique: true, where: "scim_user_name IS NOT NULL"

    reversible do |dir|
      dir.up do
        execute <<~SQL
          DELETE FROM instance_roles WHERE id IN (
            SELECT id FROM (
              SELECT id, row_number() OVER (
                PARTITION BY instance_id, user_id ORDER BY (role = 'admin') DESC, id ASC
              ) AS rn FROM instance_roles
            ) ranked WHERE rn > 1
          )
        SQL
      end
    end
    add_index :instance_roles, %i[instance_id user_id], unique: true
  end
end
