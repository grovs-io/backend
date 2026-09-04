class AddScimLastUsedAtToSsoConnections < ActiveRecord::Migration[8.1]
  def change
    add_column :sso_connections, :scim_last_used_at, :datetime
  end
end
