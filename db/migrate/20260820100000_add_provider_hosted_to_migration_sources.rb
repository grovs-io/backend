class AddProviderHostedToMigrationSources < ActiveRecord::Migration[8.1]
  def change
    add_column :migration_sources, :provider_hosted, :boolean, default: false, null: false
    add_column :migration_sources, :extra_hosts, :jsonb, default: [], null: false
  end
end
