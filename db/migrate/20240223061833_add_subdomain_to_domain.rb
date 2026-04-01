class AddSubdomainToDomain < ActiveRecord::Migration[6.1]
  def change
    add_column :domains, :subdomain, :string, null: false, unique: true
    add_index :domains, :domain, unique: false
  end
end
